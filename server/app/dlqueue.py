"""Download queue: one worker, persisted in the downloads table, resumes after restart."""
import asyncio
import logging
import os
from datetime import datetime

from app import config, db, events, library, xapi
from app.downloader import download, extract_info, normalize_url, validate_url

logger = logging.getLogger("moabom.queue")
queue: asyncio.Queue = asyncio.Queue()


async def enqueue(url: str, cats: dict | None = None, source: str = "manual", watched_by: str | None = None) -> int:
    url = normalize_url(url)
    valid, username, post_id, _ = validate_url(url)
    if not valid:
        raise ValueError("올바른 링크가 아닙니다")
    if await db.is_url_downloaded(url):
        raise ValueError("이미 받은 링크입니다")
    if await db.is_url_in_queue(url):
        raise ValueError("이미 대기 중인 링크입니다")
    cats = {k: (cats or {}).get(k) for k in library.AXIS_KEYS}
    did = await db.add_download(url, post_id, username or "unknown", cats, source, watched_by)
    await queue.put(did)
    await events.broadcast({"type": "queued", "id": did, "url": url, "username": username, "source": source,
                            "watched_by": watched_by or "", **cats})
    return did


async def _process(did: int):
    dl = await db.get_download(did)
    if not dl or dl["status"] == "cancelled":
        return
    url = dl["url"]
    valid, username, post_id, platform = validate_url(url)
    await db.update_download(did, status="downloading", progress=0, error=None)
    await events.broadcast({"type": "status", "id": did, "status": "downloading", "progress": 0})
    if not valid:
        await db.update_download(did, status="failed", error="올바른 링크가 아닙니다")
        await events.broadcast({"type": "status", "id": did, "status": "failed", "error": "올바른 링크가 아닙니다"})
        return

    info = await extract_info(url)
    title, display_name, uploaded_at = "", "", None
    username = username or "unknown"
    if info:
        username = info.get("uploader_id") or info.get("uploader") or username
        display_name = info.get("uploader") or ""
        title = (info.get("title") or info.get("description") or "")[:300]
        d = info.get("upload_date") or ""
        if len(d) == 8:
            uploaded_at = f"{d[:4]}-{d[4:6]}-{d[6:8]}T00:00:00"
        if info.get("timestamp"):
            uploaded_at = datetime.fromtimestamp(info["timestamp"]).isoformat(timespec="seconds")
    await db.update_download(did, username=username, display_name=display_name, title=title, uploaded_at=uploaded_at)
    await events.broadcast({"type": "metadata", "id": did, "username": username, "display_name": display_name,
                            "title": title})

    cats = {k: dl.get(k) for k in library.AXIS_KEYS}
    async with db.connect() as conn:
        catrows = await library.load_categories(conn)
    cats = {k: (v if v in catrows else None) for k, v in cats.items()}
    source = dl.get("source") or "manual"
    rel_dir = library.target_dir(cats, catrows, source, dl.get("watched_by"))
    out_dir = os.path.join(config.LIBRARY_ROOT, rel_dir)

    async def on_progress(pct: float):
        await db.update_download(did, progress=pct)
        await events.broadcast({"type": "progress", "id": did, "progress": pct})

    ok, files, error = await download(url, out_dir, username, post_id, platform, uploaded_at, on_progress)
    if ok:
        ids = await library.index_files(files, {**cats, "source": source, "watched_by": dl.get("watched_by"),
                                                "owner": username, "title": title, "url": url,
                                                "uploaded_at": uploaded_at})
        await db.update_download(did, status="completed", progress=100, filepath=", ".join(files),
                                 completed_at=datetime.now().isoformat())
        await db.mark_url_downloaded(url, post_id, username)
        await events.broadcast({"type": "status", "id": did, "status": "completed", "progress": 100,
                                "media_ids": ids, "username": username, "title": title})
        await events.broadcast({"type": "library", "changed": ids})
        await db.add_log("다운로드 완료", f"@{username} {title[:60] if title else url}")
        if platform == "x":
            try:
                await xapi.like_tweet(url)
            except Exception:
                pass
    else:
        await db.update_download(did, status="failed", error=error)
        await events.broadcast({"type": "status", "id": did, "status": "failed", "error": error})
        await db.add_log("다운로드 실패", f"@{username} {error or url}")


async def worker():
    logger.info("download worker started")
    while True:
        did = await queue.get()
        try:
            await _process(did)
        except Exception as e:
            logger.exception(f"download {did} crashed")
            await db.update_download(did, status="failed", error=str(e))
            await events.broadcast({"type": "status", "id": did, "status": "failed", "error": str(e)})
        finally:
            queue.task_done()


async def resume():
    await asyncio.sleep(3)
    async with db.connect() as conn:
        await conn.execute("UPDATE downloads SET status = 'queued', progress = 0 WHERE status = 'downloading'")
        await conn.commit()
        cur = await conn.execute("SELECT id FROM downloads WHERE status = 'queued' ORDER BY id")
        rows = await cur.fetchall()
    for r in rows:
        await queue.put(r["id"])
    if rows:
        logger.info(f"resumed {len(rows)} queued downloads")
