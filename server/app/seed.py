# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

from app import images
from app.db import connect, data_dir


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


def seed_wallpapers() -> None:
    root = seed_root()
    if root is None:
        return
    with connect() as conn:
        builtin_count = conn.execute("SELECT count(*) FROM assets WHERE collection = 'builtin'").fetchone()[0]
        buick_count = conn.execute("SELECT count(*) FROM assets WHERE collection = 'buick_gallery'").fetchone()[0]
    if builtin_count == 0:
        for index in range(9):
            path = root / f"Builtin{index}.jpg"
            if path.is_file():
                import_file("builtin", f"壁纸 {index + 1}", index, path)
    if buick_count == 0:
        gallery = root / "BuickGallery"
        for index in range(1, 17):
            path = gallery / f"{index:02d}.jpeg"
            if path.is_file():
                import_file("buick_gallery", f"别克壁纸 {index}", index, path)


def import_file(collection: str, title: str, order: int, path: Path) -> None:
    data = path.read_bytes()
    asset_id = str(uuid.uuid4())
    suffix = ".png" if path.suffix.lower() == ".png" else ".jpg"
    folder = data_dir() / "media" / asset_id
    original = folder / f"original{suffix}"
    preview = folder / "preview.jpg"
    width, height = images.store_original(data, original, preview)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with connect() as conn:
        conn.execute(
            """INSERT INTO assets
               (id, collection, title, sort_order, published, original_path, preview_path,
                width, height, bytes, content_hash, created_at, updated_at)
               VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (asset_id, collection, title, order, str(original), str(preview), width, height,
             len(data), hashlib.sha256(data).hexdigest(), stamp, stamp),
        )
