# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import hmac
import json
import os
import secrets
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware
from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

from app import images
from app.db import connect, data_dir, init_db, prune
from app.seed import seed_wallpapers

COLLECTIONS = {"builtin": "内置壁纸（别克专用）", "buick_gallery": "别克大联屏"}
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


def render(request: Request, name: str, context: dict) -> HTMLResponse:
    context = dict(context)
    context["request"] = request
    return templates.TemplateResponse(request, name, context)


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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

    @app.get("/v1/catalog/{collection}")
    def catalog(collection: str, request: Request) -> Response:
        stored = API_COLLECTIONS.get(collection)
        if stored is None:
            raise HTTPException(404)
        with connect() as conn:
            rows = conn.execute(
                """SELECT id, title, width, height, updated_at FROM assets
                   WHERE collection = ? AND published = 1 ORDER BY sort_order, created_at""",
                (stored,),
            ).fetchall()
        items = []
        for row in rows:
            base = str(request.base_url).rstrip("/")
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
                    at = item.get("at")
                    datetime.strptime(at, "%Y-%m-%dT%H:%M:%SZ")
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
    ) -> JSONResponse:
        device = require_device(request)
        if limited(f"works:{device['id']}", 30, 3600):
            raise HTTPException(429, "作品上报过于频繁")
        try:
            work_id = str(uuid.UUID(id))
            datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ")
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
        with connect() as conn:
            conn.execute(
                """INSERT OR IGNORE INTO works
                   (id, device_id, created_at, source, source_asset_id, width, height, mode, preview_path)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (work_id, device["id"], created_at, clip(source, 20), clip(source_asset_id, 40) or None,
                 width, height, clip(mode, 20), str(path)),
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
        today = now()[:10]
        with connect() as conn:
            stats = {
                "devices": conn.execute("SELECT count(*) FROM devices WHERE first_seen >= ?", (today,)).fetchone()[0],
                "works": conn.execute("SELECT count(*) FROM works WHERE created_at >= ?", (today,)).fetchone()[0],
                "failures": conn.execute(
                    "SELECT count(*) FROM events WHERE ok = 0 AND at >= ? AND type IN ('scan_result','apply_result','restore_result')",
                    (today,),
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
        if collection not in COLLECTIONS:
            collection = "builtin"
        with connect() as conn:
            rows = conn.execute(
                "SELECT * FROM assets WHERE collection = ? ORDER BY sort_order, created_at",
                (collection,),
            ).fetchall()
        return render(request, "assets.html", page(request, section=collection, collection=collection, title=COLLECTIONS[collection], assets=rows))

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
        if collection not in COLLECTIONS:
            raise HTTPException(400)
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

    @app.get("/admin/users", response_class=HTMLResponse)
    def users(request: Request) -> HTMLResponse:
        require_admin(request)
        with connect() as conn:
            rows = conn.execute("SELECT * FROM devices ORDER BY last_seen DESC LIMIT 200").fetchall()
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

    @app.get("/admin/failures", response_class=HTMLResponse)
    def failures(request: Request) -> HTMLResponse:
        require_admin(request)
        with connect() as conn:
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
        return render(request, "failures.html", page(request, section="failures", groups=ranked, failures=parsed[:80]))

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
