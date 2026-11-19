# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import os
import shutil
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from app import images
from app.db import LIBRARY_INSTALL, connect, data_dir

LIBRARY_NAME = "内置图库"
LIBRARY_NS = uuid.UUID("c3a0b1a2-7e4d-4f6a-9c2b-1d5e8f0a6b44")


def seed_root() -> Path | None:
    raw = os.environ.get("CARVISTA_SEED")
    if raw == "":
        return None
    if raw:
        path = Path(raw)
        return path if path.is_dir() else None
    bundled = Path(__file__).resolve().parents[1] / "seed" / "wallpapers"
    if (bundled / "Builtin0.jpg").is_file():
        return bundled
    fallback = Path(__file__).resolve().parents[2] / "ios" / "BuiltinWallpapers"
    return fallback if (fallback / "Builtin0.jpg").is_file() else None


def share_id(title: str) -> str:
    return str(uuid.uuid5(LIBRARY_NS, title))


def library_device() -> str:
    device_id = str(uuid.uuid5(LIBRARY_NS, "device"))
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with connect() as conn:
        row = conn.execute("SELECT id FROM devices WHERE install_id = ?", (LIBRARY_INSTALL,)).fetchone()
        if row:
            return row["id"]
        conn.execute(
            """INSERT OR IGNORE INTO devices
               (id, install_id, token_hash, internal_name, app_version, ios_version,
                device_model, device_machine, first_seen, last_seen)
               VALUES (?, ?, ?, ?, '', '', '', '', ?, ?)""",
            (device_id, LIBRARY_INSTALL, hashlib.sha256(b"carvista-library").hexdigest(), LIBRARY_NAME, stamp, stamp),
        )
        return conn.execute("SELECT id FROM devices WHERE install_id = ?", (LIBRARY_INSTALL,)).fetchone()["id"]


def seed_wallpapers() -> None:
    move_builtin_assets()
    root = seed_root()
    if root is None:
        return
    stock = root / "Stock"
    colors = {"Blue": "蓝色", "Brown": "棕色", "DarkBlue": "深蓝", "Green": "绿色",
              "Grey": "灰色", "Hero": "主视觉", "Purple": "紫色", "Red": "红色", "Teal": "青色"}
    for order, path in enumerate(sorted(stock.glob("*.jpg"))):
        color, appearance = path.stem.removeprefix("Wallpaper").rsplit("-", 1)
        title = colors.get(color, color) + (" · 深色" if appearance == "Dark" else " · 浅色")
        import_file("stock", title, order, path, seed_key="stock/" + path.name)
    with connect() as conn:
        buick_count = conn.execute("SELECT count(*) FROM assets WHERE collection = 'buick_gallery'").fetchone()[0]
    for index in range(9):
        path = root / f"Builtin{index}.jpg"
        if path.is_file():
            import_share(f"壁纸 {index + 1}", index, path)
    if buick_count == 0:
        gallery = root / "BuickGallery"
        for index in range(1, 17):
            path = gallery / f"{index:02d}.jpeg"
            if path.is_file():
                import_file("buick_gallery", f"别克壁纸 {index}", index, path)


def move_builtin_assets() -> None:
    with connect() as conn:
        rows = conn.execute(
            "SELECT * FROM assets WHERE collection = 'builtin' ORDER BY sort_order, created_at"
        ).fetchall()
    for row in rows:
        source = Path(row["original_path"] or "")
        if not source.is_file():
            source = Path(row["preview_path"] or "")
        if source.is_file():
            created = datetime.strptime(row["created_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            import_share(row["title"], 0, source, created=created)
        remove_asset(row)


def import_share(title: str, order: int, path: Path, created: datetime | None = None) -> None:
    share = share_id(title)
    with connect() as conn:
        if conn.execute("SELECT 1 FROM shares WHERE id = ?", (share,)).fetchone():
            return
    device_id = library_device()
    folder = data_dir() / "shares" / share
    original = folder / "original.jpg"
    preview = folder / "preview.jpg"
    width, height = images.store_original(path.read_bytes(), original, preview)
    stamp = created or (datetime.now(timezone.utc) - timedelta(seconds=order))
    with connect() as conn:
        conn.execute(
            """INSERT OR IGNORE INTO shares
               (id, device_id, title, description, width, height, preview_path, original_path, created_at)
               VALUES (?, ?, ?, '', ?, ?, ?, ?, ?)""",
            (share, device_id, title, width, height, str(preview), str(original), stamp.strftime("%Y-%m-%dT%H:%M:%SZ")),
        )


def remove_asset(row) -> None:
    with connect() as conn:
        conn.execute("DELETE FROM assets WHERE id = ?", (row["id"],))
    for column in ("original_path", "preview_path"):
        path = images.safe_file(data_dir(), row[column])
        if path:
            path.unlink(missing_ok=True)
    folder = data_dir() / "media" / row["id"]
    if folder.is_dir():
        shutil.rmtree(folder, ignore_errors=True)


def import_file(collection: str, title: str, order: int, path: Path, seed_key: str | None = None) -> None:
    if seed_key:
        with connect() as conn:
            if conn.execute("SELECT 1 FROM seeded_files WHERE key = ?", (seed_key,)).fetchone():
                return
    data = path.read_bytes()
    asset_id = str(uuid.uuid5(LIBRARY_NS, seed_key)) if seed_key else str(uuid.uuid4())
    suffix = ".png" if path.suffix.lower() == ".png" else ".jpg"
    folder = data_dir() / "media" / asset_id
    original = folder / f"original{suffix}"
    preview = folder / "preview.jpg"
    width, height = images.store_original(data, original, preview)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        if seed_key and conn.execute("SELECT 1 FROM seeded_files WHERE key = ?", (seed_key,)).fetchone():
            return
        conn.execute(
            """INSERT INTO assets
               (id, collection, title, sort_order, published, original_path, preview_path,
                width, height, bytes, content_hash, created_at, updated_at)
               VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (asset_id, collection, title, order, str(original), str(preview), width, height,
             len(data), hashlib.sha256(data).hexdigest(), stamp, stamp),
        )
        if seed_key:
            conn.execute("INSERT INTO seeded_files (key) VALUES (?)", (seed_key,))
