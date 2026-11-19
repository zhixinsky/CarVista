# SPDX-License-Identifier: GPL-3.0-or-later
import os
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path


LIBRARY_INSTALL = "carvista-library"


def data_dir() -> Path:
    path = Path(os.environ.get("CARVISTA_DATA", "/data"))
    path.mkdir(parents=True, exist_ok=True)
    return path


def db_path() -> Path:
    return data_dir() / "carvista.sqlite"


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(db_path())
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db() -> None:
    with connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY,
                install_id TEXT NOT NULL UNIQUE,
                token_hash TEXT NOT NULL,
                internal_name TEXT NOT NULL UNIQUE,
                app_version TEXT,
                ios_version TEXT,
                device_model TEXT,
                device_machine TEXT,
                first_seen TEXT NOT NULL,
                last_seen TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY,
                collection TEXT NOT NULL,
                title TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                published INTEGER NOT NULL DEFAULT 0,
                original_path TEXT,
                preview_path TEXT,
                width INTEGER,
                height INTEGER,
                bytes INTEGER,
                content_hash TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                type TEXT NOT NULL,
                ok INTEGER,
                at TEXT NOT NULL,
                payload TEXT NOT NULL,
                app_version TEXT,
                ios_version TEXT,
                FOREIGN KEY(device_id) REFERENCES devices(id)
            );
            CREATE TABLE IF NOT EXISTS works (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                source TEXT,
                source_asset_id TEXT,
                width INTEGER,
                height INTEGER,
                mode TEXT,
                preview_path TEXT,
                FOREIGN KEY(device_id) REFERENCES devices(id)
            );
            CREATE TABLE IF NOT EXISTS reports (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                app_version TEXT,
                ios_version TEXT,
                summary TEXT,
                path TEXT NOT NULL,
                bytes INTEGER,
                FOREIGN KEY(device_id) REFERENCES devices(id)
            );
            CREATE INDEX IF NOT EXISTS events_device ON events(device_id, at);
            CREATE INDEX IF NOT EXISTS events_failures ON events(type, ok, at);
            CREATE TABLE IF NOT EXISTS shares (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                title TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                width INTEGER,
                height INTEGER,
                preview_path TEXT NOT NULL,
                original_path TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY(device_id) REFERENCES devices(id)
            );
            CREATE TABLE IF NOT EXISTS share_likes (
                share_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (share_id, device_id),
                FOREIGN KEY(share_id) REFERENCES shares(id) ON DELETE CASCADE,
                FOREIGN KEY(device_id) REFERENCES devices(id)
            );
            CREATE INDEX IF NOT EXISTS reports_created ON reports(created_at);
            CREATE INDEX IF NOT EXISTS shares_created ON shares(created_at);
            """
        )
        columns = {row[1] for row in conn.execute("PRAGMA table_info(works)")}
        if "original_path" not in columns:
            conn.execute("ALTER TABLE works ADD COLUMN original_path TEXT")
        share_columns = {row[1] for row in conn.execute("PRAGMA table_info(shares)")}
        if share_columns and "description" not in share_columns:
            conn.execute("ALTER TABLE shares ADD COLUMN description TEXT NOT NULL DEFAULT ''")
        if share_columns and "author" not in share_columns:
            conn.execute("ALTER TABLE shares ADD COLUMN author TEXT NOT NULL DEFAULT ''")
        if share_columns and "likes_offset" not in share_columns:
            conn.execute("ALTER TABLE shares ADD COLUMN likes_offset INTEGER NOT NULL DEFAULT 0")
        if share_columns and "published" not in share_columns:
            conn.execute("ALTER TABLE shares ADD COLUMN published INTEGER NOT NULL DEFAULT 1")
        conn.execute("""CREATE TABLE IF NOT EXISTS gallery_categories (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL,
            sort_order INTEGER NOT NULL, hidden INTEGER NOT NULL DEFAULT 0,
            published INTEGER NOT NULL DEFAULT 1, parent_id TEXT
        )""")
        category_columns = {row[1] for row in conn.execute("PRAGMA table_info(gallery_categories)")}
        if "published" not in category_columns:
            conn.execute("ALTER TABLE gallery_categories ADD COLUMN published INTEGER NOT NULL DEFAULT 1")
        if "parent_id" not in category_columns:
            conn.execute("ALTER TABLE gallery_categories ADD COLUMN parent_id TEXT")
        conn.execute("CREATE TABLE IF NOT EXISTS seeded_files (key TEXT PRIMARY KEY)")
        for order, (key, title, kind, hidden) in enumerate([
            ("stock", "默认壁纸", "stock", 0), ("share", "精选壁纸", "share", 0),
            ("bing", "必应壁纸", "bing", 0), ("commons", "主题搜图", "commons", 0),
            ("buick_gallery", "别克车机壁纸", "buick", 0), ("test", "测试", "test", 1),
        ]):
            conn.execute(
                """INSERT OR IGNORE INTO gallery_categories
                   (id, title, kind, sort_order, hidden, published) VALUES (?, ?, ?, ?, ?, 1)""",
                (key, title, kind, order, hidden),
            )
        conn.execute("UPDATE gallery_categories SET title = '精选壁纸' WHERE id = 'share' AND title = '共享壁纸'")


def prune(days: int = 180) -> None:
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    with connect() as conn:
        old_works = conn.execute("SELECT id, preview_path, original_path FROM works WHERE created_at < ?", (cutoff,)).fetchall()
        for row in old_works:
            for column in ("preview_path", "original_path"):
                if row[column]:
                    try:
                        Path(row[column]).unlink(missing_ok=True)
                    except OSError:
                        pass
        conn.execute("DELETE FROM works WHERE created_at < ?", (cutoff,))
        conn.execute("DELETE FROM events WHERE at < ?", (cutoff,))
        old_reports = conn.execute("SELECT path FROM reports WHERE created_at < ?", (cutoff,)).fetchall()
        for row in old_reports:
            try:
                Path(row["path"]).unlink(missing_ok=True)
            except OSError:
                pass
        conn.execute("DELETE FROM reports WHERE created_at < ?", (cutoff,))
        old_shares = conn.execute(
            """SELECT preview_path, original_path FROM shares
               WHERE created_at < ?
                 AND device_id NOT IN (SELECT id FROM devices WHERE install_id = ?)""",
            (cutoff, LIBRARY_INSTALL),
        ).fetchall()
        for row in old_shares:
            for column in ("preview_path", "original_path"):
                try:
                    Path(row[column]).unlink(missing_ok=True)
                except OSError:
                    pass
        conn.execute(
            """DELETE FROM shares WHERE created_at < ?
               AND device_id NOT IN (SELECT id FROM devices WHERE install_id = ?)""",
            (cutoff, LIBRARY_INSTALL),
        )
