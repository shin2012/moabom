"""SQLite access + schema/migrations."""
import os
from contextlib import asynccontextmanager
from datetime import datetime

import aiosqlite

from app import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS downloads (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT NOT NULL,
    tweet_id TEXT,
    username TEXT,
    display_name TEXT,
    title TEXT,
    uploaded_at TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    progress REAL DEFAULT 0,
    country TEXT,
    optionA TEXT,
    optionB TEXT,
    filepath TEXT,
    error TEXT,
    created_at TEXT NOT NULL,
    completed_at TEXT,
    watched_by TEXT,
    c1 INTEGER, c2 INTEGER, c3 INTEGER,
    source TEXT DEFAULT 'manual'
);

CREATE TABLE IF NOT EXISTS watched (
    username TEXT PRIMARY KEY,
    interval_minutes INTEGER DEFAULT 60,
    last_checked TEXT,
    last_tweet_id TEXT,
    enabled INTEGER DEFAULT 1,
    platform TEXT DEFAULT 'twitter',
    account_status TEXT DEFAULT 'unknown',
    status_checked_at TEXT
);

CREATE TABLE IF NOT EXISTS downloaded_urls (
    url TEXT PRIMARY KEY,
    tweet_id TEXT,
    username TEXT,
    downloaded_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS activity_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    time TEXT NOT NULL,
    action TEXT NOT NULL,
    detail TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS counters (
    name TEXT PRIMARY KEY,
    value INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS categories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    axis INTEGER NOT NULL,
    name TEXT NOT NULL,
    folder TEXT NOT NULL,
    sort INTEGER NOT NULL DEFAULT 0,
    rev INTEGER NOT NULL DEFAULT 0,
    deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_categories_rev ON categories(rev);

CREATE TABLE IF NOT EXISTS media (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT NOT NULL,
    thumb TEXT,
    kind TEXT NOT NULL,
    size INTEGER NOT NULL DEFAULT 0,
    mtime REAL NOT NULL DEFAULT 0,
    width INTEGER,
    height INTEGER,
    duration REAL,
    probed INTEGER NOT NULL DEFAULT 0,
    c1 INTEGER, c2 INTEGER, c3 INTEGER,
    source TEXT NOT NULL DEFAULT 'manual',
    owner TEXT,
    watched_by TEXT,
    title TEXT,
    source_url TEXT,
    uploaded_at TEXT,
    added_at TEXT NOT NULL,
    favorite INTEGER NOT NULL DEFAULT 0,
    rev INTEGER NOT NULL DEFAULT 0,
    deleted INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_media_path_live ON media(path) WHERE deleted = 0;
CREATE INDEX IF NOT EXISTS idx_media_rev ON media(rev);
CREATE INDEX IF NOT EXISTS idx_media_added ON media(added_at);

CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    name TEXT,
    created_at TEXT NOT NULL,
    last_used TEXT,
    expires_at TEXT
);

CREATE TABLE IF NOT EXISTS login_failures (
    ip TEXT NOT NULL,
    at REAL NOT NULL
);
"""


@asynccontextmanager
async def connect():
    conn = await aiosqlite.connect(config.DB_PATH, timeout=30)
    conn.row_factory = aiosqlite.Row
    await conn.execute("PRAGMA journal_mode=WAL")
    await conn.execute("PRAGMA busy_timeout=30000")
    try:
        yield conn
    finally:
        await conn.close()


async def _columns(conn, table: str) -> set[str]:
    cur = await conn.execute(f"PRAGMA table_info({table})")
    return {r["name"] for r in await cur.fetchall()}


async def init_db():
    os.makedirs(os.path.dirname(config.DB_PATH) or ".", exist_ok=True)
    async with connect() as conn:
        await conn.executescript(SCHEMA)
        # Migrations for databases created by older versions.
        cols = await _columns(conn, "downloads")
        for col, ddl in (
            ("display_name", "TEXT"), ("uploaded_at", "TEXT"), ("watched_by", "TEXT"),
            ("c1", "INTEGER"), ("c2", "INTEGER"), ("c3", "INTEGER"), ("source", "TEXT DEFAULT 'manual'"),
        ):
            if col not in cols:
                await conn.execute(f"ALTER TABLE downloads ADD COLUMN {col} {ddl}")
        wcols = await _columns(conn, "watched")
        for col, ddl in (("platform", "TEXT DEFAULT 'twitter'"), ("account_status", "TEXT DEFAULT 'unknown'"),
                         ("status_checked_at", "TEXT")):
            if col not in wcols:
                await conn.execute(f"ALTER TABLE watched ADD COLUMN {col} {ddl}")
        await _merge_watched_case_duplicates(conn)
        await conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_watched_nocase ON watched(username COLLATE NOCASE)")
        await conn.execute("CREATE INDEX IF NOT EXISTS idx_downloaded_tweet ON downloaded_urls(tweet_id)")
        # Instagram support was removed.
        await conn.execute("DELETE FROM watched WHERE platform = 'instagram'")
        await conn.execute("DELETE FROM settings WHERE key IN ('ig_logged_in')")
        await conn.execute("INSERT OR IGNORE INTO counters(name, value) VALUES ('rev', 0)")
        await conn.commit()


async def next_revs(conn, n: int = 1) -> int:
    """Reserve n consecutive revision numbers; returns the first one. Caller commits."""
    cur = await conn.execute("UPDATE counters SET value = value + ? WHERE name = 'rev' RETURNING value", (n,))
    row = await cur.fetchone()
    return row["value"] - n + 1


async def current_rev(conn) -> int:
    cur = await conn.execute("SELECT value FROM counters WHERE name = 'rev'")
    row = await cur.fetchone()
    return row["value"] if row else 0


# ─── settings ───
async def get_setting(key: str, default: str | None = None) -> str | None:
    async with connect() as conn:
        cur = await conn.execute("SELECT value FROM settings WHERE key = ?", (key,))
        row = await cur.fetchone()
        return row["value"] if row and row["value"] is not None else default


async def set_setting(key: str, value: str | None):
    async with connect() as conn:
        await conn.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (key, value))
        await conn.commit()


# ─── activity log ───
MAX_LOGS = 300


async def add_log(action: str, detail: str = ""):
    async with connect() as conn:
        await conn.execute("INSERT INTO activity_logs (time, action, detail) VALUES (?, ?, ?)",
                           (datetime.now().isoformat(), action, detail))
        await conn.execute("DELETE FROM activity_logs WHERE id NOT IN "
                           "(SELECT id FROM activity_logs ORDER BY id DESC LIMIT ?)", (MAX_LOGS,))
        await conn.commit()


async def get_logs(limit: int = 50):
    async with connect() as conn:
        cur = await conn.execute("SELECT time, action, detail FROM activity_logs ORDER BY id DESC LIMIT ?", (limit,))
        return [dict(r) for r in await cur.fetchall()]


# ─── downloads ───
async def add_download(url: str, tweet_id: str | None, username: str, cats: dict, source: str = "manual",
                       watched_by: str | None = None) -> int:
    async with connect() as conn:
        cur = await conn.execute(
            "INSERT INTO downloads (url, tweet_id, username, c1, c2, c3, source, watched_by, status, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?)",
            (url, tweet_id, username, cats.get("c1"), cats.get("c2"), cats.get("c3"), source, watched_by,
             datetime.now().isoformat()),
        )
        await conn.commit()
        return cur.lastrowid


async def update_download(download_id: int, **kwargs):
    if not kwargs:
        return
    async with connect() as conn:
        sets = ", ".join(f"{k} = ?" for k in kwargs)
        await conn.execute(f"UPDATE downloads SET {sets} WHERE id = ?", [*kwargs.values(), download_id])
        await conn.commit()


async def get_downloads(limit: int = 200):
    async with connect() as conn:
        cur = await conn.execute("SELECT * FROM downloads ORDER BY id DESC LIMIT ?", (limit,))
        return [dict(r) for r in await cur.fetchall()]


async def get_download(download_id: int):
    async with connect() as conn:
        cur = await conn.execute("SELECT * FROM downloads WHERE id = ?", (download_id,))
        row = await cur.fetchone()
        return dict(row) if row else None


async def delete_download(download_id: int):
    async with connect() as conn:
        await conn.execute("DELETE FROM downloads WHERE id = ?", (download_id,))
        await conn.commit()


async def delete_downloads_by_status(status: str) -> int:
    async with connect() as conn:
        cur = await conn.execute("DELETE FROM downloads WHERE status = ?", (status,))
        await conn.commit()
        return cur.rowcount


async def is_url_downloaded(url: str, post_id: str | None = None) -> bool:
    """X account names are case-insensitive, so the same post can arrive as x.com/Foo/... or x.com/foo/...
    Match on the post id when known, otherwise on the URL ignoring case."""
    async with connect() as conn:
        if post_id:
            cur = await conn.execute("SELECT 1 FROM downloaded_urls WHERE tweet_id = ? OR url = ? COLLATE NOCASE LIMIT 1",
                                     (post_id, url))
        else:
            cur = await conn.execute("SELECT 1 FROM downloaded_urls WHERE url = ? COLLATE NOCASE LIMIT 1", (url,))
        return await cur.fetchone() is not None


async def is_url_in_queue(url: str, post_id: str | None = None) -> bool:
    async with connect() as conn:
        cur = await conn.execute("SELECT 1 FROM downloads WHERE status IN ('queued', 'downloading') AND "
                                 "(url = ? COLLATE NOCASE OR (? IS NOT NULL AND tweet_id = ?)) LIMIT 1",
                                 (url, post_id, post_id))
        return await cur.fetchone() is not None


async def mark_url_downloaded(url: str, tweet_id: str | None, username: str):
    async with connect() as conn:
        await conn.execute("INSERT OR IGNORE INTO downloaded_urls (url, tweet_id, username, downloaded_at) "
                           "VALUES (?, ?, ?, ?)", (url, tweet_id, username, datetime.now().isoformat()))
        await conn.commit()


# ─── watched accounts (X only) ───
async def find_watched(username: str) -> dict | None:
    async with connect() as conn:
        cur = await conn.execute("SELECT * FROM watched WHERE username = ? COLLATE NOCASE", (username,))
        row = await cur.fetchone()
        return dict(row) if row else None


async def add_watched(username: str, interval_minutes: int) -> tuple[str, bool]:
    """Adds an account (names are case-insensitive). Returns (stored name, already_existed)."""
    async with connect() as conn:
        cur = await conn.execute("SELECT username FROM watched WHERE username = ? COLLATE NOCASE", (username,))
        row = await cur.fetchone()
        if row:
            await conn.execute("UPDATE watched SET interval_minutes = ?, enabled = 1 WHERE username = ?",
                               (interval_minutes, row["username"]))
            await conn.commit()
            return row["username"], True
        await conn.execute("INSERT INTO watched (username, interval_minutes, enabled, platform) "
                           "VALUES (?, ?, 1, 'twitter')", (username, interval_minutes))
        await conn.commit()
        return username, False


async def remove_watched(username: str):
    async with connect() as conn:
        await conn.execute("DELETE FROM watched WHERE username = ? COLLATE NOCASE", (username,))
        await conn.commit()


async def _merge_watched_case_duplicates(conn) -> int:
    """Collapse watched rows whose names differ only by case (keeps the most advanced cursor)."""
    cur = await conn.execute("SELECT * FROM watched ORDER BY username")
    groups: dict[str, list[dict]] = {}
    for r in await cur.fetchall():
        groups.setdefault(r["username"].lower(), []).append(dict(r))
    removed = 0
    for rows in groups.values():
        if len(rows) < 2:
            continue
        rows.sort(key=lambda r: (int(r["last_tweet_id"] or 0), r["last_checked"] or ""), reverse=True)
        for extra in rows[1:]:
            await conn.execute("DELETE FROM watched WHERE username = ?", (extra["username"],))
            removed += 1
    return removed


async def get_watched():
    async with connect() as conn:
        # rowid = insertion order (add_watched updates existing rows in place) → newest first
        cur = await conn.execute("SELECT * FROM watched WHERE enabled = 1 ORDER BY rowid DESC")
        return [dict(r) for r in await cur.fetchall()]


async def update_watched_last_checked(username: str, last_tweet_id: str | None = None):
    async with connect() as conn:
        if last_tweet_id:
            await conn.execute("UPDATE watched SET last_checked = ?, last_tweet_id = ? WHERE username = ? COLLATE NOCASE",
                               (datetime.now().isoformat(), last_tweet_id, username))
        else:
            await conn.execute("UPDATE watched SET last_checked = ? WHERE username = ? COLLATE NOCASE",
                               (datetime.now().isoformat(), username))
        await conn.commit()


async def update_account_status(username: str, status: str):
    async with connect() as conn:
        await conn.execute("UPDATE watched SET account_status = ?, status_checked_at = ? WHERE username = ? COLLATE NOCASE",
                           (status, datetime.now().isoformat(), username))
        await conn.commit()


async def get_last_download_by_watcher(username: str):
    async with connect() as conn:
        cur = await conn.execute("SELECT completed_at, url FROM downloads WHERE watched_by = ? AND status = 'completed' "
                                 "ORDER BY completed_at DESC LIMIT 1", (username,))
        row = await cur.fetchone()
        return dict(row) if row else None


# ─── likes watch state ───
async def get_likes_watch_state() -> dict:
    return {
        "enabled": (await get_setting("likes_watch_enabled")) == "true",
        "last_tweet_id": await get_setting("likes_last_tweet_id"),
        "last_checked": await get_setting("likes_last_checked"),
    }


async def update_likes_watch_state(enabled: bool | None = None, last_tweet_id: str | None = None,
                                   last_checked: str | None = None):
    if enabled is not None:
        await set_setting("likes_watch_enabled", "true" if enabled else "")
    if last_tweet_id is not None:
        await set_setting("likes_last_tweet_id", last_tweet_id)
    if last_checked is not None:
        await set_setting("likes_last_checked", last_checked)
