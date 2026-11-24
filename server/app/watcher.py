"""Watches X accounts (and the user's likes) and queues new media posts."""
import asyncio
import logging
from datetime import datetime, timedelta

from app import db, xapi
from app.downloader import list_user_likes, list_user_media

logger = logging.getLogger("moabom.watcher")

CYCLE_MINUTES = 15
MAX_ACCOUNTS_PER_CYCLE = 30


async def check_account(username: str, last_id: str | None, enqueue) -> int:
    limit = 50 if not last_id else 20
    posts = await list_user_media(username, limit=limit)
    if not posts:
        await db.update_watched_last_checked(username)
        return 0
    new, newest = 0, last_id
    for p in posts:
        pid, url = p["id"], p["url"]
        if last_id and int(pid) <= int(last_id):
            continue
        if not newest or int(pid) > int(newest):
            newest = pid
        if await db.is_url_downloaded(url, pid):
            continue
        try:
            await enqueue(url, None, "watch", username)
            new += 1
        except ValueError:
            pass
    await db.update_watched_last_checked(username, newest)
    logger.info(f"@{username}: {new} new (newest={newest})")
    return new


UNAVAILABLE_STATUSES = ("suspended", "not_found", "unavailable")

# accounts with a full-timeline backfill in progress → {"videos_only", "listed", "queued"}
backfills: dict[str, dict] = {}


async def backfill_account(username: str, videos_only: bool, enqueue) -> int:
    """Queue every media post of the account (whole /media timeline), skipping ones already received."""
    key = username.lower()
    state = backfills[key] = {"videos_only": videos_only, "listed": None, "queued": 0}
    try:
        posts = await list_user_media(username, limit=None, timeout=1800)
        state["listed"] = len(posts)
        newest = None
        for p in posts:
            if not newest or int(p["id"]) > int(newest):
                newest = p["id"]
            if videos_only and not p.get("has_video"):
                continue
            if await db.is_url_downloaded(p["url"], p["id"]):
                continue
            try:
                await enqueue(p["url"], None, "watch", username)
                state["queued"] += 1
            except ValueError:
                pass
        acc = await db.find_watched(username)
        if newest and acc and (not acc.get("last_tweet_id") or int(newest) > int(acc["last_tweet_id"])):
            await db.update_watched_last_checked(username, newest)
        await db.add_log("전체 받기", f"@{username} {'영상만' if videos_only else '전체'} → {state['queued']}건 "
                                    f"(게시물 {len(posts)}개 확인)")
        logger.info(f"backfill @{username}: listed {len(posts)}, queued {state['queued']}")
        return state["queued"]
    finally:
        backfills.pop(key, None)


async def check_likes(enqueue) -> int:
    state = await db.get_likes_watch_state()
    x_user = await db.get_setting("x_username")
    if not state["enabled"] or not x_user:
        return 0
    last_id = state["last_tweet_id"]
    likes = await list_user_likes(x_user, limit=50 if not last_id else 20)
    new, newest = 0, last_id
    for l in likes:
        pid, url = l["id"], l["url"]
        if last_id and int(pid) <= int(last_id):
            continue
        if not newest or int(pid) > int(newest):
            newest = pid
        if await db.is_url_downloaded(url, pid):
            continue
        try:
            await enqueue(url, None, "likes", None)
            new += 1
        except ValueError:
            pass
    await db.update_likes_watch_state(last_tweet_id=newest, last_checked=datetime.now().isoformat())
    return new


async def loop(enqueue):
    await asyncio.sleep(30)
    last_likes = None
    while True:
        try:
            accounts = sorted(await db.get_watched(), key=lambda a: a.get("last_checked") or "")
            now = datetime.now()
            due = [a for a in accounts if not a.get("last_checked") or
                   now - datetime.fromisoformat(a["last_checked"]) >= timedelta(minutes=CYCLE_MINUTES)]
            gap = max(15.0, CYCLE_MINUTES * 60 / max(1, len(accounts)))
            for a in due[:MAX_ACCOUNTS_PER_CYCLE]:
                try:
                    await check_account(a["username"], a.get("last_tweet_id") or None, enqueue)
                except Exception as e:
                    logger.error(f"check @{a['username']}: {e}")
                await asyncio.sleep(gap)
            if last_likes is None or now - last_likes >= timedelta(minutes=CYCLE_MINUTES):
                await check_likes(enqueue)
                last_likes = now
            for a in accounts:
                sc = a.get("status_checked_at")
                if sc and datetime.now() - datetime.fromisoformat(sc) < timedelta(hours=1):
                    continue
                status = await xapi.account_status(a["username"])
                await db.update_account_status(a["username"], status)
                await asyncio.sleep(2)
        except Exception as e:
            logger.error(f"watcher loop: {e}")
        await asyncio.sleep(30)
