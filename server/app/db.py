# SPDX-License-Identifier: GPL-3.0-or-later
import os
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path


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
            CREATE INDEX IF NOT EXISTS events_device ON events(device_id, at);
            CREATE INDEX IF NOT EXISTS events_failures ON events(type, ok, at);
            """
        )


def prune(days: int = 180) -> None:
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    with connect() as conn:
        old_works = conn.execute("SELECT id, preview_path FROM works WHERE created_at < ?", (cutoff,)).fetchall()
        for row in old_works:
            if row["preview_path"]:
                try:
                    Path(row["preview_path"]).unlink(missing_ok=True)
                except OSError:
                    pass
        conn.execute("DELETE FROM works WHERE created_at < ?", (cutoff,))
        conn.execute("DELETE FROM events WHERE at < ?", (cutoff,))
