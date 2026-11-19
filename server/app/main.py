# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import hmac
import json
import os
import re
import secrets
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware
from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

from app import images
from app.db import LIBRARY_INSTALL, connect, data_dir, init_db, prune
from app.seed import seed_wallpapers

COLLECTIONS = {"builtin": "内置壁纸（别克专用）", "buick_gallery": "别克壁纸"}
API_COLLECTIONS = {"builtin": "builtin", "buick": "buick_gallery", "buick_gallery": "buick_gallery"}
EVENT_TYPES = {
    "launch",
    "catalog_shown",
    "pick_catalog",
    "import_source",
    "save_wallpaper",
    "scan_result",
    "apply_result",
    "restore_result",
}
NAME_ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789"
_HITS: dict[str, list[float]] = {}

templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))
SHANGHAI = timezone(timedelta(hours=8))
_INSTANT = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")


def render(request: Request, name: str, context: dict) -> HTMLResponse:
    context = dict(context)
    with connect() as conn:
        context["gallery_categories"] = conn.execute("SELECT * FROM gallery_categories ORDER BY sort_order, id").fetchall()
    context["request"] = request
    return templates.TemplateResponse(request, name, context)


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_instant(value: str) -> datetime:
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    moment = datetime.fromisoformat(text)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc)


def format_shanghai(value) -> str:
    text = str(value or "").strip()
    if not text or not _INSTANT.match(text):
        return text
    try:
        return parse_instant(text).astimezone(SHANGHAI).strftime("%Y-%m-%d %H:%M:%S")
    except ValueError:
        return text


def localize_times(value):
    if isinstance(value, dict):
        return {key: localize_times(item) for key, item in value.items()}
    if isinstance(value, list):
        return [localize_times(item) for item in value]
    if isinstance(value, str):
        return format_shanghai(value)
    return value


def shanghai_today() -> tuple[str, str]:
    start = datetime.now(SHANGHAI).replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + timedelta(days=1)
    return (
        start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        end.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    )


templates.env.filters["sh"] = format_shanghai


def public_base(request: Request) -> str:
    """Address phones should use. Synology's proxy talks to 127.0.0.1 and leaves that host in the request."""
    configured = os.environ.get("CARVISTA_PUBLIC_URL", "").strip().rstrip("/")
    if configured:
        return configured
    proto = (request.headers.get("x-forwarded-proto") or request.url.scheme or "https").split(",")[0].strip()
    forwarded = request.headers.get("x-forwarded-host", "")
    host = (forwarded or request.headers.get("host") or request.url.netloc).split(",")[0].strip()
    name = host.split(":")[0].strip("[]").lower()
    if name and name not in {"127.0.0.1", "localhost", "::1"}:
        return f"{proto}://{host}"
    return "https://carplay.dokor.cn"


def create_app() -> FastAPI:
    _HITS.clear()
    secret = os.environ.get("CARVISTA_SESSION_SECRET", "")
    password = os.environ.get("CARVISTA_ADMIN_PASSWORD", "")
    if not secret or not password:
        raise RuntimeError("需要 CARVISTA_SESSION_SECRET 和 CARVISTA_ADMIN_PASSWORD")
    init_db()
    seed_wallpapers()

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        init_db()
        seed_wallpapers()
        prune()
        yield

    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.mount("/static", StaticFiles(directory=str(Path(__file__).parent / "static")), name="static")
    app.add_middleware(ProxyHeadersMiddleware, trusted_hosts="*")
    app.add_middleware(SessionMiddleware, secret_key=secret, https_only=False, same_site="lax")

    @app.get("/")
    def root() -> RedirectResponse:
        return RedirectResponse("/admin", status_code=303)

    @app.get("/v1/health")
    def health() -> dict:
        return {"ok": True}

    @app.post("/v1/devices")
    async def register_device(request: Request) -> JSONResponse:
        if limited(f"register:{client_ip(request)}", 10, 3600):
            raise HTTPException(429, "登记过于频繁")
        body = await request.json()
        try:
            install_id = str(uuid.UUID(str(body.get("install_id", ""))))
        except (ValueError, TypeError, AttributeError):
            raise HTTPException(400, "install_id 无效")
        token = secrets.token_urlsafe(32)
        token_hash = hash_token(token)
        fields = (
            clip(body.get("app_version"), 40),
            clip(body.get("ios_version"), 40),
            clip(body.get("device_model"), 40),
            clip(body.get("device_machine"), 40),
            now(),
        )
        with connect() as conn:
            existing = conn.execute("SELECT id FROM devices WHERE install_id = ?", (install_id,)).fetchone()
            if existing:
                conn.execute(
                    """UPDATE devices SET token_hash = ?, app_version = ?, ios_version = ?,
                       device_model = ?, device_machine = ?, last_seen = ? WHERE id = ?""",
                    (token_hash, *fields, existing["id"]),
                )
            else:
                conn.execute(
                    """INSERT INTO devices
                       (id, install_id, token_hash, internal_name, app_version, ios_version,
                        device_model, device_machine, first_seen, last_seen)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (str(uuid.uuid4()), install_id, token_hash, new_internal_name(conn), *fields, fields[-1]),
                )
        return JSONResponse({"device_token": token})

    @app.get("/v1/gallery/categories")
    def gallery_categories() -> JSONResponse:
        with connect() as conn:
            rows = conn.execute(
                """SELECT id, title, kind, hidden, published FROM gallery_categories
                   WHERE published = 1 AND parent_id IS NULL ORDER BY sort_order, id"""
            ).fetchall()
        return JSONResponse({"items": [dict(row) for row in rows]}, headers={"Cache-Control": "no-store"})

    @app.get("/v1/gallery/categories/{category_id}/groups")
    def category_groups(category_id: str, request: Request) -> JSONResponse:
        base = public_base(request)
        with connect() as conn:
            parent = conn.execute(
                "SELECT id, kind FROM gallery_categories WHERE id = ? AND published = 1 AND parent_id IS NULL",
                (category_id,),
            ).fetchone()
            if parent is None:
                raise HTTPException(404)
            children = conn.execute(
                """SELECT id, title, hidden FROM gallery_categories
                   WHERE parent_id = ? AND published = 1 ORDER BY sort_order, id""",
                (category_id,),
            ).fetchall()
            items = [group_payload(conn, row["id"], row["title"], row["hidden"], base) for row in children]
            loose = conn.execute(
                "SELECT COUNT(*) FROM assets WHERE collection = ? AND published = 1",
                (category_id,),
            ).fetchone()[0]
            if loose:
                items.append(group_payload(conn, category_id, "未分组", 0, base))
        return JSONResponse({"items": items}, headers={"Cache-Control": "no-store"})

    @app.get("/admin/categories", response_class=HTMLResponse)
    def category_list(request: Request) -> HTMLResponse:
        require_admin(request)
        return render(request, "categories.html", page(request, section="categories"))

    @app.post("/admin/categories")
    def add_category(request: Request, title: str = Form(), hidden: str = Form("0"),
                     published: str = Form("1"), csrf: str = Form()) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        clean_title = clip(title, 60)
        hidden_flag, published_flag = category_flags(hidden, published)
        if not clean_title:
            raise HTTPException(400, "请输入分类名称")
        key = "custom-" + uuid.uuid4().hex
        with connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            order = conn.execute("SELECT COALESCE(MAX(sort_order), 0) + 1 FROM gallery_categories").fetchone()[0]
            conn.execute(
                """INSERT INTO gallery_categories
                   (id, title, kind, sort_order, hidden, published) VALUES (?, ?, 'catalog', ?, ?, ?)""",
                (key, clean_title, order, hidden_flag, published_flag),
            )
        return redirect_assets(key, "分类已新增，可上传壁纸")

    @app.post("/admin/categories/{category_id}")
    def edit_category(request: Request, category_id: str, title: str = Form(),
                      sort_order: int = Form(), hidden: str = Form("0"),
                      published: str = Form("1"), csrf: str = Form()) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        clean_title = clip(title, 60)
        hidden_flag, published_flag = category_flags(hidden, published)
        if not clean_title or not 0 <= sort_order <= 1000000:
            raise HTTPException(400, "请填写名称和有效顺序")
        with connect() as conn:
            result = conn.execute(
                """UPDATE gallery_categories
                   SET title = ?, sort_order = ?, hidden = ?, published = ? WHERE id = ?""",
                (clean_title, sort_order, hidden_flag, published_flag, category_id),
            )
            if result.rowcount == 0:
                raise HTTPException(404)
        return RedirectResponse("/admin/categories?msg=分类已更新", status_code=303)

    @app.get("/admin/categories/{category_id}/source", response_class=HTMLResponse)
    def category_source(request: Request, category_id: str) -> HTMLResponse:
        require_admin(request)
        with connect() as conn:
            category = conn.execute("SELECT * FROM gallery_categories WHERE id = ?", (category_id,)).fetchone()
        if category is None:
            raise HTTPException(404)
        return render(request, "category_source.html", page(request, section=category_id, category=category))

    @app.get("/v1/catalog/{collection}")
    def catalog(collection: str, request: Request) -> Response:
        stored = API_COLLECTIONS.get(collection, collection)
        with connect() as conn:
            if stored != "builtin" and conn.execute(
                """SELECT 1 FROM gallery_categories
                   WHERE id = ? AND published = 1 AND kind IN ('catalog', 'buick', 'test', 'stock', 'series')""",
                (stored,),
            ).fetchone() is None:
                raise HTTPException(404)
            rows = conn.execute(
                """SELECT id, title, width, height, updated_at FROM assets
                   WHERE collection = ? AND published = 1 ORDER BY sort_order, created_at""",
                (stored,),
            ).fetchall()
        base = public_base(request)
        items = []
        for row in rows:
            items.append({
                "id": row["id"],
                "title": row["title"],
                "width": row["width"] or 0,
                "height": row["height"] or 0,
                "preview_url": f"{base}/v1/media/{row['id']}/preview",
                "original_url": f"{base}/v1/media/{row['id']}/original",
                "updated_at": row["updated_at"],
            })
        payload = {"revision": items[-1]["updated_at"] if items else "", "items": items}
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        etag = '"' + hashlib.sha256(raw).hexdigest() + '"'
        if request.headers.get("if-none-match") == etag:
            return Response(status_code=304, headers={"ETag": etag})
        return Response(raw, media_type="application/json", headers={"ETag": etag})

    @app.get("/v1/media/{asset_id}/{kind}")
    def media(asset_id: str, kind: str) -> FileResponse:
        if kind not in {"preview", "original"}:
            raise HTTPException(404)
        column = "preview_path" if kind == "preview" else "original_path"
        with connect() as conn:
            row = conn.execute(
                f"SELECT {column} AS path FROM assets WHERE id = ? AND published = 1",
                (asset_id,),
            ).fetchone()
        path = images.safe_file(data_dir(), row["path"] if row else None)
        if path is None:
            raise HTTPException(404)
        media_type = "image/jpeg" if path.suffix.lower() in {".jpg", ".jpeg"} else "image/png"
        return FileResponse(path, media_type=media_type)

    @app.post("/v1/events")
    async def post_events(request: Request) -> JSONResponse:
        device = require_device(request)
        if limited(f"events:{device['id']}", 60, 60):
            raise HTTPException(429, "上报过于频繁")
        body = await request.json()
        incoming = body.get("events")
        if not isinstance(incoming, list) or len(incoming) > 50:
            raise HTTPException(400, "events 无效")
        accepted, rejected = [], []
        with connect() as conn:
            for item in incoming:
                event_id = str(item.get("id", "")) if isinstance(item, dict) else ""
                try:
                    event_id = str(uuid.UUID(event_id))
                    event_type = item.get("type")
                    if event_type not in EVENT_TYPES:
                        raise ValueError
                    at = parse_instant(item.get("at")).strftime("%Y-%m-%dT%H:%M:%SZ")
                    payload = item.get("payload") if isinstance(item.get("payload"), dict) else {}
                    encoded = json.dumps(payload, ensure_ascii=False)
                    if len(encoded) > 8000:
                        raise ValueError
                    ok = item.get("ok")
                    ok_value = None if ok is None else (1 if ok else 0)
                except (ValueError, TypeError, AttributeError):
                    if event_id:
                        rejected.append(event_id)
                    continue
                conn.execute(
                    """INSERT OR IGNORE INTO events
                       (id, device_id, type, ok, at, payload, app_version, ios_version)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                    (event_id, device["id"], event_type, ok_value, at, encoded,
                     clip(item.get("app_version"), 40), clip(item.get("ios_version"), 40)),
                )
                accepted.append(event_id)
            conn.execute("UPDATE devices SET last_seen = ? WHERE id = ?", (now(), device["id"]))
        return JSONResponse({"accepted": accepted, "rejected": rejected})

    @app.post("/v1/reports")
    async def post_report(request: Request) -> JSONResponse:
        device = require_device(request)
        if limited(f"reports:{device['id']}", 12, 3600):
            raise HTTPException(429, "诊断报告过于频繁")
        raw = await request.body()
        if not raw or len(raw) > 1_000_000:
            raise HTTPException(400, "诊断报告过大或为空")
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            raise HTTPException(400, "诊断报告无效")
        if not isinstance(body, dict):
            raise HTTPException(400, "诊断报告无效")
        report_id = str(uuid.uuid4())
        folder = data_dir() / "reports"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{report_id}.json"
        path.write_text(json.dumps(body, ensure_ascii=False, indent=2), encoding="utf-8")
        summary = clip(body.get("message") or body.get("lastApply") or body.get("lastScan") or "诊断报告", 200)
        stamp = now()
        with connect() as conn:
            conn.execute(
                """INSERT INTO reports
                   (id, device_id, created_at, app_version, ios_version, summary, path, bytes)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (report_id, device["id"], stamp, clip(body.get("appVersion"), 40), clip(body.get("system"), 40),
                 summary, str(path), len(raw)),
            )
            conn.execute("UPDATE devices SET last_seen = ? WHERE id = ?", (stamp, device["id"]))
        return JSONResponse({"id": report_id})

    @app.post("/v1/works")
    async def post_work(
        request: Request,
        id: str = Form(),
        source: str = Form(""),
        source_asset_id: str = Form(""),
        width: int = Form(0),
        height: int = Form(0),
        mode: str = Form(""),
        created_at: str = Form(""),
        preview: UploadFile = File(),
        original: UploadFile | None = File(None),
    ) -> JSONResponse:
        device = require_device(request)
        if limited(f"works:{device['id']}", 30, 3600):
            raise HTTPException(429, "作品上报过于频繁")
        try:
            work_id = str(uuid.UUID(id))
            created_at = parse_instant(created_at).strftime("%Y-%m-%dT%H:%M:%SZ")
        except (ValueError, TypeError):
            raise HTTPException(400, "作品信息不完整")
        if width < 0 or height < 0 or width > 20000 or height > 20000:
            raise HTTPException(400, "尺寸无效")
        with connect() as conn:
            existing = conn.execute("SELECT id FROM works WHERE id = ?", (work_id,)).fetchone()
            if existing:
                return JSONResponse({"ok": True, "duplicate": True})
        data = await preview.read()
        try:
            images.valid_preview(data)
        except images.ImageRejected as error:
            raise HTTPException(400, str(error)) from error
        folder = data_dir() / "works" / device["id"]
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{work_id}.jpg"
        path.write_bytes(data)
        original_path = None
        if original is not None and original.filename:
            original_data = await original.read()
            try:
                suffix = images.valid_original(original_data)
            except images.ImageRejected as error:
                raise HTTPException(400, str(error)) from error
            stored = folder / f"{work_id}-original{suffix}"
            stored.write_bytes(original_data)
            original_path = str(stored)
        with connect() as conn:
            conn.execute(
                """INSERT OR IGNORE INTO works
                   (id, device_id, created_at, source, source_asset_id, width, height, mode, preview_path, original_path)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (work_id, device["id"], created_at, clip(source, 20), clip(source_asset_id, 40) or None,
                 width, height, clip(mode, 20), str(path), original_path),
            )
        return JSONResponse({"ok": True})

    @app.get("/admin/login", response_class=HTMLResponse)
    def login_page(request: Request) -> HTMLResponse:
        if request.session.get("admin"):
            return RedirectResponse("/admin", status_code=303)
        return render(request, "login.html", page(request))

    @app.post("/admin/login")
    async def login(request: Request) -> RedirectResponse:
        form = await request.form()
        check_csrf(request, form)
        if limited(f"login:{client_ip(request)}", 5, 600):
            return RedirectResponse("/admin/login?msg=登录尝试过多，请稍后再试", status_code=303)
        user = os.environ.get("CARVISTA_ADMIN_USER", "admin")
        password = os.environ.get("CARVISTA_ADMIN_PASSWORD", "")
        given_user = str(form.get("username", ""))
        given_password = str(form.get("password", ""))
        if not hmac.compare_digest(given_user, user) or not hmac.compare_digest(given_password, password):
            return RedirectResponse("/admin/login?msg=账号或密码不正确", status_code=303)
        request.session["admin"] = True
        return RedirectResponse("/admin", status_code=303)

    @app.post("/admin/logout")
    async def logout(request: Request) -> RedirectResponse:
        form = await request.form()
        check_csrf(request, form)
        request.session.clear()
        return RedirectResponse("/admin/login", status_code=303)

    @app.get("/admin", response_class=HTMLResponse)
    def overview(request: Request) -> HTMLResponse:
        require_admin(request)
        prune()
        day_start, day_end = shanghai_today()
        with connect() as conn:
            stats = {
                "devices": conn.execute(
                    "SELECT count(*) FROM devices WHERE install_id != ? AND first_seen >= ? AND first_seen < ?",
                    (LIBRARY_INSTALL, day_start, day_end),
                ).fetchone()[0],
                "works": conn.execute("SELECT count(*) FROM works WHERE created_at >= ? AND created_at < ?", (day_start, day_end)).fetchone()[0],
                "failures": conn.execute(
                    "SELECT count(*) FROM events WHERE ok = 0 AND at >= ? AND at < ? AND type IN ('scan_result','apply_result','restore_result')",
                    (day_start, day_end),
                ).fetchone()[0],
            }
            top = conn.execute(
                """SELECT payload FROM events
                   WHERE ok = 0 AND type IN ('scan_result','apply_result')
                   ORDER BY at DESC LIMIT 200"""
            ).fetchall()
        counts: dict[str, int] = {}
        for row in top:
            message = payload_message(row["payload"]) or "无文案"
            counts[message] = counts.get(message, 0) + 1
        ranked = sorted(counts.items(), key=lambda item: item[1], reverse=True)[:8]
        return render(request, "overview.html", page(request, section="overview", stats=stats, ranked=ranked))

    @app.get("/admin/assets", response_class=HTMLResponse)
    def asset_list(request: Request, collection: str = "builtin") -> HTMLResponse:
        require_admin(request)
        with connect() as conn:
            category = conn.execute(
                "SELECT * FROM gallery_categories WHERE id = ? AND kind IN ('catalog', 'buick', 'test', 'stock', 'series')",
                (collection,),
            ).fetchone()
            if category is None and collection != "builtin":
                raise HTTPException(404)
            rows = conn.execute(
                "SELECT * FROM assets WHERE collection = ? ORDER BY sort_order, created_at",
                (collection,),
            ).fetchall()
            groups = group_rows(conn, collection) if category and not category["parent_id"] else []
        can_folders = bool(category and not category["parent_id"] and category["kind"] in {"catalog", "series"})
        return render(request, "assets.html", page(
            request, section=collection, collection=collection,
            title=category["title"] if category else COLLECTIONS["builtin"], assets=rows,
            groups=groups, can_folders=can_folders,
        ))

    @app.post("/admin/assets/batch")
    async def batch_assets(request: Request) -> JSONResponse:
        require_admin(request)
        form = await request.form()
        check_csrf(request, form)
        collection = str(form.get("collection") or "")
        mode = str(form.get("mode") or "files")
        uploads = [item for item in form.getlist("files") if hasattr(item, "read")]
        paths = [str(item) for item in form.getlist("paths")]
        if len(uploads) > 40:
            raise HTTPException(400, "一次最多上传 40 张")
        with connect() as conn:
            category = conn.execute("SELECT * FROM gallery_categories WHERE id = ?", (collection,)).fetchone()
            if category is None and collection != "builtin":
                raise HTTPException(400, "分类不存在")
            added = skipped = failed = 0
            for index, upload in enumerate(uploads):
                path = paths[index] if index < len(paths) else (upload.filename or "")
                filename = upload.filename or path.rsplit("/", 1)[-1]
                if Path(filename).suffix.lower() not in {".jpg", ".jpeg", ".png"}:
                    failed += 1
                    continue
                data = await upload.read()
                target = collection
                if mode == "folders" and category and not category["parent_id"] and category["kind"] in {"catalog", "series"}:
                    folder = series_folder(path)
                    if folder is None:
                        failed += 1
                        continue
                    if folder:
                        target = ensure_series(conn, collection, folder)
                title = clip(Path(filename).stem, 60) or "壁纸"
                try:
                    outcome = save_asset(conn, target, title, filename, data)
                except images.ImageRejected:
                    failed += 1
                    continue
                if outcome == "added":
                    added += 1
                else:
                    skipped += 1
        return JSONResponse({"added": added, "skipped": skipped, "failed": failed})

    @app.post("/admin/assets")
    async def create_asset(
        request: Request,
        collection: str = Form(),
        title: str = Form(),
        published: str | None = Form(None),
        file: UploadFile = File(),
        csrf: str = Form(),
    ) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        with connect() as conn:
            valid = conn.execute(
                "SELECT 1 FROM gallery_categories WHERE id = ? AND kind IN ('catalog', 'buick', 'test', 'stock', 'series')",
                (collection,),
            ).fetchone()
        if not valid and collection != "builtin":
            raise HTTPException(400, "分类不存在或不支持上传")
        clean_title = clip(title.strip(), 60)
        if not clean_title:
            return redirect_assets(collection, "请填写名称")
        data = await file.read()
        asset_id = str(uuid.uuid4())
        suffix = ".png" if (file.filename or "").lower().endswith(".png") else ".jpg"
        folder = data_dir() / "media" / asset_id
        original = folder / f"original{suffix}"
        preview = folder / "preview.jpg"
        try:
            width, height = images.store_original(data, original, preview)
        except images.ImageRejected as error:
            return redirect_assets(collection, str(error))
        stamp = now()
        with connect() as conn:
            order = conn.execute(
                "SELECT COALESCE(MAX(sort_order), 0) + 1 FROM assets WHERE collection = ?",
                (collection,),
            ).fetchone()[0]
            conn.execute(
                """INSERT INTO assets
                   (id, collection, title, sort_order, published, original_path, preview_path,
                    width, height, bytes, content_hash, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (asset_id, collection, clean_title, order, 1 if published else 0, str(original), str(preview),
                 width, height, len(data), hashlib.sha256(data).hexdigest(), stamp, stamp),
            )
        return redirect_assets(collection, "已添加")

    @app.post("/admin/assets/{asset_id}")
    async def update_asset(
        request: Request,
        asset_id: str,
        title: str = Form(),
        published: str | None = Form(None),
        csrf: str = Form(),
    ) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        clean_title = clip(title.strip(), 60)
        with connect() as conn:
            row = conn.execute("SELECT collection FROM assets WHERE id = ?", (asset_id,)).fetchone()
            if row is None or not clean_title:
                return RedirectResponse("/admin/assets", status_code=303)
            conn.execute(
                "UPDATE assets SET title = ?, published = ?, updated_at = ? WHERE id = ?",
                (clean_title, 1 if published else 0, now(), asset_id),
            )
        return redirect_assets(row["collection"], "已保存")

    @app.post("/admin/assets/{asset_id}/edit")
    async def edit_asset(
        request: Request,
        asset_id: str,
        title: str = Form(),
        file: UploadFile | None = File(None),
        csrf: str = Form(),
    ) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        clean_title = clip(title.strip(), 60)
        with connect() as conn:
            row = conn.execute("SELECT * FROM assets WHERE id = ?", (asset_id,)).fetchone()
            if row is None or not clean_title:
                return RedirectResponse("/admin/assets", status_code=303)
            conn.execute("UPDATE assets SET title = ?, updated_at = ? WHERE id = ?", (clean_title, now(), asset_id))
        if file is not None and file.filename:
            data = await file.read()
            suffix = ".png" if file.filename.lower().endswith(".png") else ".jpg"
            folder = data_dir() / "media" / asset_id
            original = folder / f"original{suffix}"
            preview = folder / "preview.jpg"
            try:
                width, height = images.store_original(data, original, preview)
            except images.ImageRejected as error:
                return redirect_assets(row["collection"], str(error))
            with connect() as conn:
                conn.execute(
                    """UPDATE assets SET original_path = ?, preview_path = ?, width = ?, height = ?,
                       bytes = ?, content_hash = ?, updated_at = ? WHERE id = ?""",
                    (str(original), str(preview), width, height, len(data), hashlib.sha256(data).hexdigest(), now(), asset_id),
                )
        return redirect_assets(row["collection"], "已保存")

    @app.post("/admin/assets/{asset_id}/replace")
    async def replace_asset(request: Request, asset_id: str, file: UploadFile = File(), csrf: str = Form()) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        with connect() as conn:
            row = conn.execute("SELECT * FROM assets WHERE id = ?", (asset_id,)).fetchone()
        if row is None:
            raise HTTPException(404)
        data = await file.read()
        suffix = ".png" if (file.filename or "").lower().endswith(".png") else ".jpg"
        folder = data_dir() / "media" / asset_id
        original = folder / f"original{suffix}"
        preview = folder / "preview.jpg"
        try:
            width, height = images.store_original(data, original, preview)
        except images.ImageRejected as error:
            return redirect_assets(row["collection"], str(error))
        with connect() as conn:
            conn.execute(
                """UPDATE assets SET original_path = ?, preview_path = ?, width = ?, height = ?,
                   bytes = ?, content_hash = ?, updated_at = ? WHERE id = ?""",
                (str(original), str(preview), width, height, len(data), hashlib.sha256(data).hexdigest(), now(), asset_id),
            )
        return redirect_assets(row["collection"], "已替换原图")

    @app.post("/admin/assets/{asset_id}/move")
    async def move_asset(request: Request, asset_id: str, direction: str = Form(), csrf: str = Form()) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        with connect() as conn:
            row = conn.execute("SELECT * FROM assets WHERE id = ?", (asset_id,)).fetchone()
            if row is None:
                return RedirectResponse("/admin/assets", status_code=303)
            operator = "<" if direction == "up" else ">"
            order_sql = "DESC" if direction == "up" else "ASC"
            neighbor = conn.execute(
                f"""SELECT id, sort_order FROM assets WHERE collection = ? AND sort_order {operator} ?
                    ORDER BY sort_order {order_sql} LIMIT 1""",
                (row["collection"], row["sort_order"]),
            ).fetchone()
            if neighbor:
                conn.execute("UPDATE assets SET sort_order = ? WHERE id = ?", (neighbor["sort_order"], row["id"]))
                conn.execute("UPDATE assets SET sort_order = ? WHERE id = ?", (row["sort_order"], neighbor["id"]))
        return redirect_assets(row["collection"])

    @app.post("/admin/assets/{asset_id}/delete")
    async def delete_asset(request: Request, asset_id: str, csrf: str = Form()) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        with connect() as conn:
            row = conn.execute("SELECT collection FROM assets WHERE id = ?", (asset_id,)).fetchone()
            conn.execute("DELETE FROM assets WHERE id = ?", (asset_id,))
        folder = data_dir() / "media" / asset_id
        if folder.is_dir():
            for child in folder.iterdir():
                child.unlink(missing_ok=True)
            folder.rmdir()
        return redirect_assets(row["collection"] if row else "builtin", "已删除")

    @app.get("/admin/assets/{asset_id}/preview")
    def admin_asset_preview(request: Request, asset_id: str) -> FileResponse:
        require_admin(request)
        with connect() as conn:
            row = conn.execute("SELECT preview_path FROM assets WHERE id = ?", (asset_id,)).fetchone()
        path = images.safe_file(data_dir(), row["preview_path"] if row else None)
        if path is None:
            raise HTTPException(404)
        return FileResponse(path, media_type="image/jpeg")

    @app.get("/admin/assets/{asset_id}/original")
    def admin_asset_original(request: Request, asset_id: str) -> FileResponse:
        require_admin(request)
        with connect() as conn:
            row = conn.execute("SELECT original_path FROM assets WHERE id = ?", (asset_id,)).fetchone()
        path = images.safe_file(data_dir(), row["original_path"] if row else None)
        if path is None:
            raise HTTPException(404)
        media_type = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
        return FileResponse(path, media_type=media_type)

    @app.get("/admin/users", response_class=HTMLResponse)
    def users(request: Request) -> HTMLResponse:
        require_admin(request)
        with connect() as conn:
            rows = conn.execute(
                "SELECT * FROM devices WHERE install_id != ? ORDER BY last_seen DESC LIMIT 200",
                (LIBRARY_INSTALL,),
            ).fetchall()
        return render(request, "users.html", page(request, section="users", users=rows))

    @app.get("/admin/users/{device_id}", response_class=HTMLResponse)
    def user_detail(request: Request, device_id: str) -> HTMLResponse:
        require_admin(request)
        with connect() as conn:
            device = conn.execute("SELECT * FROM devices WHERE id = ?", (device_id,)).fetchone()
            if device is None:
                raise HTTPException(404)
            events = conn.execute(
                "SELECT * FROM events WHERE device_id = ? ORDER BY at DESC LIMIT 100",
                (device_id,),
            ).fetchall()
            works = conn.execute(
                "SELECT * FROM works WHERE device_id = ? ORDER BY created_at DESC LIMIT 50",
                (device_id,),
            ).fetchall()
        return render(request, "user.html", page(request, section="users", device=device, events=events, works=works))

    @app.get("/admin/works", response_class=HTMLResponse)
    def works(request: Request) -> HTMLResponse:
        require_admin(request)
        with connect() as conn:
            rows = conn.execute(
                """SELECT works.*, devices.internal_name FROM works
                   JOIN devices ON devices.id = works.device_id
                   ORDER BY works.created_at DESC LIMIT 120"""
            ).fetchall()
        return render(request, "works.html", page(request, section="works", works=rows))

    @app.get("/admin/works/{work_id}/file")
    def work_file(request: Request, work_id: str) -> FileResponse:
        require_admin(request)
        with connect() as conn:
            row = conn.execute("SELECT preview_path FROM works WHERE id = ?", (work_id,)).fetchone()
        path = images.safe_file(data_dir(), row["preview_path"] if row else None)
        if path is None:
            raise HTTPException(404)
        return FileResponse(path, media_type="image/jpeg")

    @app.get("/admin/works/{work_id}/original")
    def work_original(request: Request, work_id: str, inline: int = 0) -> FileResponse:
        require_admin(request)
        with connect() as conn:
            row = conn.execute("SELECT original_path, width, height FROM works WHERE id = ?", (work_id,)).fetchone()
        path = images.safe_file(data_dir(), row["original_path"] if row else None)
        if path is None:
            raise HTTPException(404)
        media_type = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
        if inline:
            return FileResponse(path, media_type=media_type)
        name = f"carvista-{row['width']}x{row['height']}{path.suffix.lower()}"
        return FileResponse(path, media_type=media_type, filename=name)

    @app.get("/admin/failures")
    def old_failures() -> RedirectResponse:
        return RedirectResponse("/admin/diagnostics", status_code=303)

    @app.get("/admin/diagnostics", response_class=HTMLResponse)
    def diagnostics(request: Request) -> HTMLResponse:
        require_admin(request)
        with connect() as conn:
            reports = conn.execute(
                """SELECT reports.*, devices.internal_name, devices.device_machine FROM reports
                   JOIN devices ON devices.id = reports.device_id
                   ORDER BY reports.created_at DESC LIMIT 200"""
            ).fetchall()
            rows = conn.execute(
                """SELECT events.*, devices.internal_name, devices.device_machine FROM events
                   JOIN devices ON devices.id = events.device_id
                   WHERE events.ok = 0 AND events.type IN ('scan_result','apply_result','restore_result')
                   ORDER BY events.at DESC LIMIT 300"""
            ).fetchall()
        groups: dict[str, dict] = {}
        parsed = []
        for row in rows:
            payload = json.loads(row["payload"] or "{}")
            message = payload.get("message") or "无文案"
            item = dict(row)
            item["message"] = message
            item["target"] = size_text(payload)
            parsed.append(item)
            bucket = groups.setdefault(message, {"message": message, "count": 0, "devices": set(), "last": row["at"]})
            bucket["count"] += 1
            bucket["devices"].add(row["device_id"])
        ranked = sorted(groups.values(), key=lambda item: item["count"], reverse=True)
        for item in ranked:
            item["devices"] = len(item["devices"])
        return render(request, "failures.html", page(
            request, section="diagnostics", groups=ranked, failures=parsed[:80], reports=reports,
        ))

    @app.get("/admin/diagnostics/{report_id}", response_class=HTMLResponse)
    def diagnostic_report(request: Request, report_id: str) -> HTMLResponse:
        require_admin(request)
        with connect() as conn:
            row = conn.execute(
                """SELECT reports.*, devices.internal_name, devices.device_machine FROM reports
                   JOIN devices ON devices.id = reports.device_id WHERE reports.id = ?""",
                (report_id,),
            ).fetchone()
        if row is None:
            raise HTTPException(404)
        path = images.safe_file(data_dir(), row["path"])
        if path is None:
            text = "报告文件已丢失。"
        else:
            try:
                text = json.dumps(localize_times(json.loads(path.read_text(encoding="utf-8"))), ensure_ascii=False, indent=2)
            except json.JSONDecodeError:
                text = path.read_text(encoding="utf-8")
        return render(request, "report.html", page(request, section="diagnostics", report=row, text=text))

    @app.get("/v1/shares")
    def list_shares(request: Request) -> JSONResponse:
        device = optional_device(request)
        device_id = device["id"] if device else ""
        base = public_base(request)
        with connect() as conn:
            rows = conn.execute(
                """SELECT shares.id, shares.title, shares.description, shares.author, shares.width, shares.height, shares.created_at,
                          max(0, shares.likes_offset + (SELECT count(*) FROM share_likes WHERE share_id = shares.id)) AS likes,
                          EXISTS(SELECT 1 FROM share_likes WHERE share_id = shares.id AND device_id = ?) AS liked
                   FROM shares
                   WHERE shares.published = 1
                   ORDER BY likes DESC, shares.created_at DESC
                   LIMIT 100""",
                (device_id,),
            ).fetchall()
        items = [{
            "id": row["id"],
            "title": row["title"],
            "description": row["description"] or "",
            "author": row["author"] or "",
            "width": row["width"] or 0,
            "height": row["height"] or 0,
            "likes": row["likes"],
            "liked": bool(row["liked"]),
            "preview_url": f"{base}/v1/shares/{row['id']}/preview",
            "original_url": f"{base}/v1/shares/{row['id']}/original",
            "created_at": row["created_at"],
        } for row in rows]
        return JSONResponse({"items": items})

    @app.post("/v1/shares")
    async def create_share(
        request: Request,
        id: str = Form(),
        title: str = Form(""),
        description: str = Form(""),
        author: str = Form(""),
        width: int = Form(0),
        height: int = Form(0),
        preview: UploadFile = File(),
        original: UploadFile = File(),
    ) -> JSONResponse:
        device = require_device(request)
        if limited(f"shares:{device['id']}", 30, 3600):
            raise HTTPException(429, "共享过于频繁")
        try:
            share_id = str(uuid.UUID(id))
        except (ValueError, TypeError):
            raise HTTPException(400, "共享信息不完整")
        if width < 1 or height < 1 or width > 20000 or height > 20000:
            raise HTTPException(400, "尺寸无效")
        clean_title = clip(title, 60) or "精选壁纸"
        clean_description = clip(description, 200)
        with connect() as conn:
            existing = conn.execute("SELECT device_id FROM shares WHERE id = ?", (share_id,)).fetchone()
            if existing:
                if existing["device_id"] != device["id"]:
                    raise HTTPException(403, "只能编辑自己共享的壁纸")
                return JSONResponse({"ok": True, "duplicate": True})
        preview_data = await preview.read()
        original_data = await original.read()
        try:
            images.valid_preview(preview_data)
            suffix = images.valid_original(original_data)
        except images.ImageRejected as error:
            raise HTTPException(400, str(error)) from error
        folder = data_dir() / "shares" / share_id
        folder.mkdir(parents=True, exist_ok=True)
        preview_path = folder / "preview.jpg"
        original_path = folder / f"original{suffix}"
        preview_path.write_bytes(preview_data)
        original_path.write_bytes(original_data)
        with connect() as conn:
            conn.execute(
                """INSERT OR IGNORE INTO shares
                   (id, device_id, title, description, author, width, height, preview_path, original_path, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (share_id, device["id"], clean_title, clean_description, clip(author, 60), width, height, str(preview_path), str(original_path), now()),
            )
        return JSONResponse({"ok": True})

    @app.get("/v1/shares/{share_id}/metadata")
    def share_metadata(request: Request, share_id: str) -> JSONResponse:
        device = require_device(request)
        with connect() as conn:
            row = conn.execute("SELECT title, description, author, device_id FROM shares WHERE id = ?", (share_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "精选壁纸不存在")
        if row["device_id"] != device["id"]:
            raise HTTPException(403, "只能编辑自己共享的壁纸")
        return JSONResponse({"title": row["title"], "description": row["description"] or "", "author": row["author"] or ""})

    @app.patch("/v1/shares/{share_id}/metadata")
    def update_share(request: Request, share_id: str, title: str = Form(), description: str = Form(""), author: str = Form("")) -> JSONResponse:
        device = require_device(request)
        clean_title = clip(title, 60)
        if not clean_title:
            raise HTTPException(400, "请输入壁纸名称")
        with connect() as conn:
            row = conn.execute("SELECT device_id FROM shares WHERE id = ?", (share_id,)).fetchone()
            if row is None:
                raise HTTPException(404, "精选壁纸不存在")
            if row["device_id"] != device["id"]:
                raise HTTPException(403, "只能编辑自己共享的壁纸")
            conn.execute("UPDATE shares SET title = ?, description = ?, author = ? WHERE id = ?",
                         (clean_title, clip(description, 200), clip(author, 60), share_id))
        return JSONResponse({"ok": True})

    @app.post("/v1/shares/{share_id}/like")
    def like_share(request: Request, share_id: str) -> JSONResponse:
        device = require_device(request)
        if limited(f"likes:{device['id']}", 120, 3600):
            raise HTTPException(429, "点赞过于频繁")
        with connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT likes_offset FROM shares WHERE id = ? AND published = 1", (share_id,)).fetchone()
            if row is None:
                raise HTTPException(404)
            liked = conn.execute(
                "SELECT 1 FROM share_likes WHERE share_id = ? AND device_id = ?",
                (share_id, device["id"]),
            ).fetchone()
            if liked:
                conn.execute("DELETE FROM share_likes WHERE share_id = ? AND device_id = ?", (share_id, device["id"]))
            else:
                conn.execute(
                    "INSERT INTO share_likes (share_id, device_id, created_at) VALUES (?, ?, ?)",
                    (share_id, device["id"], now()),
                )
            count = conn.execute("SELECT count(*) FROM share_likes WHERE share_id = ?", (share_id,)).fetchone()[0]
            likes = max(0, count + row["likes_offset"])
        return JSONResponse({"likes": likes, "liked": not liked})

    @app.get("/v1/shares/{share_id}/{kind}")
    def share_media(share_id: str, kind: str) -> FileResponse:
        if kind not in {"preview", "original"}:
            raise HTTPException(404)
        column = "preview_path" if kind == "preview" else "original_path"
        with connect() as conn:
            row = conn.execute(f"SELECT {column} AS path FROM shares WHERE id = ? AND published = 1", (share_id,)).fetchone()
        path = images.safe_file(data_dir(), row["path"] if row else None)
        if path is None:
            raise HTTPException(404)
        media_type = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
        return FileResponse(path, media_type=media_type)

    @app.get("/admin/shares", response_class=HTMLResponse)
    def admin_shares(request: Request) -> HTMLResponse:
        require_admin(request)
        with connect() as conn:
            rows = conn.execute(
                """SELECT shares.*, devices.internal_name,
                          max(0, shares.likes_offset + (SELECT count(*) FROM share_likes WHERE share_id = shares.id)) AS likes
                   FROM shares JOIN devices ON devices.id = shares.device_id
                   ORDER BY likes DESC, shares.created_at DESC LIMIT 200"""
            ).fetchall()
        return render(request, "shares.html", page(request, section="shares", shares=rows))

    @app.get("/admin/shares/{share_id}/media/{kind}")
    def admin_share_media(request: Request, share_id: str, kind: str, download: bool = False) -> FileResponse:
        require_admin(request)
        if kind not in {"preview", "original"}:
            raise HTTPException(404)
        column = "preview_path" if kind == "preview" else "original_path"
        with connect() as conn:
            row = conn.execute(f"SELECT {column} AS path FROM shares WHERE id = ?", (share_id,)).fetchone()
        path = images.safe_file(data_dir(), row["path"] if row else None)
        if path is None:
            raise HTTPException(404)
        media_type = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
        return FileResponse(path, media_type=media_type,
                            filename=f"carvista-{share_id}{path.suffix.lower()}" if download else None)

    @app.post("/admin/shares/{share_id}/publish")
    def publish_share(request: Request, share_id: str, published: str = Form(""), csrf: str = Form()) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        with connect() as conn:
            result = conn.execute("UPDATE shares SET published = ? WHERE id = ?", (int(published == "on"), share_id))
            if result.rowcount == 0:
                raise HTTPException(404, "精选壁纸不存在")
        return RedirectResponse("/admin/shares?msg=发布状态已更新", status_code=303)

    @app.post("/admin/shares/{share_id}/edit")
    def edit_share(request: Request, share_id: str, title: str = Form(), description: str = Form(""),
                   likes: int = Form(), csrf: str = Form()) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        clean_title = clip(title, 60)
        if not clean_title:
            raise HTTPException(400, "请输入壁纸名称")
        if not 0 <= likes <= 1_000_000_000:
            raise HTTPException(400, "点赞数需在 0 到 1000000000 之间")
        with connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            if conn.execute("SELECT 1 FROM shares WHERE id = ?", (share_id,)).fetchone() is None:
                raise HTTPException(404, "精选壁纸不存在")
            count = conn.execute("SELECT count(*) FROM share_likes WHERE share_id = ?", (share_id,)).fetchone()[0]
            conn.execute("UPDATE shares SET title = ?, description = ?, likes_offset = ? WHERE id = ?",
                         (clean_title, clip(description, 200), likes - count, share_id))
        return RedirectResponse("/admin/shares?msg=精选壁纸已更新", status_code=303)

    @app.post("/admin/shares/{share_id}/likes")
    def set_share_likes(request: Request, share_id: str, likes: int = Form(), csrf: str = Form()) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        if likes < 0 or likes > 1_000_000_000:
            raise HTTPException(400, "点赞数需在 0 到 1000000000 之间")
        with connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            if conn.execute("SELECT 1 FROM shares WHERE id = ?", (share_id,)).fetchone() is None:
                raise HTTPException(404, "精选壁纸不存在")
            count = conn.execute("SELECT count(*) FROM share_likes WHERE share_id = ?", (share_id,)).fetchone()[0]
            conn.execute("UPDATE shares SET likes_offset = ? WHERE id = ?", (likes - count, share_id))
        return RedirectResponse("/admin/shares?msg=点赞数已更新", status_code=303)

    @app.post("/admin/shares/{share_id}/title")
    def set_share_title(request: Request, share_id: str, title: str = Form(), csrf: str = Form()) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        clean_title = clip(title, 60)
        if not clean_title:
            raise HTTPException(400, "请输入壁纸名称")
        with connect() as conn:
            result = conn.execute("UPDATE shares SET title = ? WHERE id = ?", (clean_title, share_id))
            if result.rowcount == 0:
                raise HTTPException(404, "精选壁纸不存在")
        return RedirectResponse("/admin/shares?msg=壁纸名称已更新", status_code=303)

    @app.post("/admin/shares/{share_id}/delete")
    async def delete_share(request: Request, share_id: str, csrf: str = Form()) -> RedirectResponse:
        require_admin(request)
        check_csrf(request, {"csrf": csrf})
        with connect() as conn:
            row = conn.execute("SELECT preview_path, original_path FROM shares WHERE id = ?", (share_id,)).fetchone()
            conn.execute("DELETE FROM share_likes WHERE share_id = ?", (share_id,))
            conn.execute("DELETE FROM shares WHERE id = ?", (share_id,))
        if row:
            for column in ("preview_path", "original_path"):
                path = images.safe_file(data_dir(), row[column])
                if path:
                    path.unlink(missing_ok=True)
            folder = data_dir() / "shares" / share_id
            if folder.is_dir():
                folder.rmdir()
        return RedirectResponse("/admin/shares?msg=已移除", status_code=303)

    return app


def page(request: Request, **extra):
    token = request.session.get("csrf")
    if not token:
        token = secrets.token_urlsafe(24)
        request.session["csrf"] = token
    extra.update(csrf=token, msg=request.query_params.get("msg", ""), section=extra.get("section", ""))
    return extra


def require_admin(request: Request) -> None:
    if not request.session.get("admin"):
        raise HTTPException(303, headers={"Location": "/admin/login"})


def check_csrf(request: Request, form) -> None:
    given = str(form.get("csrf", ""))
    stored = str(request.session.get("csrf", ""))
    if not stored or not hmac.compare_digest(given, stored):
        raise HTTPException(403, "页面已过期，请刷新后重试")


def optional_device(request: Request):
    header = request.headers.get("authorization", "")
    if not header.lower().startswith("bearer "):
        return None
    try:
        return require_device(request)
    except HTTPException:
        return None


def require_device(request: Request):
    header = request.headers.get("authorization", "")
    if not header.lower().startswith("bearer "):
        raise HTTPException(401)
    token_hash = hash_token(header.split(" ", 1)[1].strip())
    with connect() as conn:
        row = conn.execute("SELECT * FROM devices WHERE token_hash = ?", (token_hash,)).fetchone()
    if row is None:
        raise HTTPException(401)
    return row


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def new_internal_name(conn) -> str:
    for _ in range(8):
        name = "cv-" + "".join(secrets.choice(NAME_ALPHABET) for _ in range(8))
        if conn.execute("SELECT 1 FROM devices WHERE internal_name = ?", (name,)).fetchone() is None:
            return name
    raise HTTPException(500, "无法分配内部用户名")


def clip(value, limit: int) -> str:
    return str(value or "").strip()[:limit]


def series_folder(path: str) -> str | None:
    parts = [part for part in str(path).replace("\\", "/").split("/") if part not in {"", ".", ".."}]
    if any(part == "__MACOSX" or part.startswith(".") for part in parts):
        return None
    if len(parts) < 2:
        return ""
    return clip(parts[-2], 60)


def ensure_series(conn, parent_id: str, title: str) -> str:
    row = conn.execute(
        "SELECT id FROM gallery_categories WHERE parent_id = ? AND title = ?",
        (parent_id, title),
    ).fetchone()
    if row:
        return row["id"]
    key = "series-" + uuid.uuid4().hex[:12]
    order = conn.execute(
        "SELECT COALESCE(MAX(sort_order), 0) + 1 FROM gallery_categories WHERE parent_id = ?",
        (parent_id,),
    ).fetchone()[0]
    conn.execute(
        """INSERT INTO gallery_categories
           (id, title, kind, sort_order, hidden, published, parent_id)
           VALUES (?, ?, 'catalog', ?, 0, 1, ?)""",
        (key, title, order, parent_id),
    )
    conn.execute(
        "UPDATE gallery_categories SET kind = 'series' WHERE id = ? AND kind = 'catalog'",
        (parent_id,),
    )
    return key


def save_asset(conn, collection: str, title: str, filename: str, data: bytes) -> str:
    digest = hashlib.sha256(data).hexdigest()
    if conn.execute(
        "SELECT 1 FROM assets WHERE collection = ? AND content_hash = ?",
        (collection, digest),
    ).fetchone():
        return "skipped"
    asset_id = str(uuid.uuid4())
    suffix = ".png" if Path(filename).suffix.lower() == ".png" else ".jpg"
    folder = data_dir() / "media" / asset_id
    original = folder / f"original{suffix}"
    preview = folder / "preview.jpg"
    width, height = images.store_original(data, original, preview)
    stamp = now()
    order = conn.execute(
        "SELECT COALESCE(MAX(sort_order), 0) + 1 FROM assets WHERE collection = ?",
        (collection,),
    ).fetchone()[0]
    conn.execute(
        """INSERT INTO assets
           (id, collection, title, sort_order, published, original_path, preview_path,
            width, height, bytes, content_hash, created_at, updated_at)
           VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (asset_id, collection, title, order, str(original), str(preview),
         width, height, len(data), digest, stamp, stamp),
    )
    return "added"


def group_rows(conn, parent_id: str) -> list[dict]:
    rows = conn.execute(
        "SELECT * FROM gallery_categories WHERE parent_id = ? ORDER BY sort_order, id",
        (parent_id,),
    ).fetchall()
    return [admin_group(conn, row) for row in rows]


def admin_group(conn, row) -> dict:
    cover = conn.execute(
        """SELECT id FROM assets WHERE collection = ? AND published = 1
           ORDER BY sort_order, created_at LIMIT 1""",
        (row["id"],),
    ).fetchone()
    count = conn.execute("SELECT COUNT(*) FROM assets WHERE collection = ?", (row["id"],)).fetchone()[0]
    item = dict(row)
    item["count"] = count
    item["cover"] = cover["id"] if cover else ""
    return item


def group_payload(conn, collection: str, title: str, hidden: int, base: str) -> dict:
    count = conn.execute(
        "SELECT COUNT(*) FROM assets WHERE collection = ? AND published = 1",
        (collection,),
    ).fetchone()[0]
    cover = conn.execute(
        """SELECT id FROM assets WHERE collection = ? AND published = 1
           ORDER BY sort_order, created_at LIMIT 1""",
        (collection,),
    ).fetchone()
    return {
        "id": collection,
        "title": title,
        "hidden": hidden,
        "count": count,
        "preview_url": f"{base}/v1/media/{cover['id']}/preview" if cover else "",
    }


def category_flags(hidden: str, published: str) -> tuple[int, int]:
    if hidden not in {"0", "1"} or published not in {"0", "1"}:
        raise HTTPException(400, "请选择显示和上下架状态")
    return int(hidden), int(published)


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def limited(key: str, limit: int, window: float) -> bool:
    current = time.time()
    hits = [item for item in _HITS.get(key, []) if current - item < window]
    if len(hits) >= limit:
        _HITS[key] = hits
        return True
    hits.append(current)
    _HITS[key] = hits
    return False


def redirect_assets(collection: str, msg: str = "") -> RedirectResponse:
    suffix = f"&msg={quote(msg)}" if msg else ""
    return RedirectResponse(f"/admin/assets?collection={collection}{suffix}", status_code=303)


def payload_message(raw: str) -> str:
    try:
        return str(json.loads(raw).get("message") or "")
    except (json.JSONDecodeError, AttributeError):
        return ""


def size_text(payload: dict) -> str:
    width = payload.get("target_width")
    height = payload.get("target_height")
    if not width or not height:
        return ""
    mode = payload.get("mode") or ""
    return f"{width} × {height} {mode}".strip()


try:
    app = create_app()
except RuntimeError:
    app = FastAPI()
