import asyncio
import os
import re
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import auth, config, db, dlqueue, library, watcher
from app.downloader import extract_info, list_user_likes, list_user_media

router = APIRouter(dependencies=[Depends(auth.require_auth)])


# ─── watched X accounts ───
class WatchReq(BaseModel):
    username: str
    interval_minutes: int = 60
    from_now: bool = True


@router.post("/api/watch")
async def add_watch(req: WatchReq):
    username = req.username.strip().lstrip("@")
    m = re.match(r"^(?:https?://(?:www\.)?(?:x|twitter)\.com/)?([A-Za-z0-9_]{1,15})/?$", username)
    if not m:
        raise HTTPException(400, "올바른 X 계정 이름이 아닙니다")
    username = m.group(1)
    await db.add_watched(username, req.interval_minutes)
    if req.from_now:
        posts = await list_user_media(username, limit=1)
        if posts:
            await db.update_watched_last_checked(username, posts[0]["id"])
    await db.add_log("감시 추가", f"@{username}")
    return {"ok": True, "username": username}


@router.get("/api/watch")
async def list_watch():
    out = []
    async with db.connect() as conn:
        cur = await conn.execute("SELECT watched_by AS u, COUNT(*) AS n, MAX(added_at) AS last FROM media "
                                 "WHERE deleted = 0 AND watched_by IS NOT NULL GROUP BY watched_by")
        counts = {r["u"]: dict(r) for r in await cur.fetchall()}
    for w in await db.get_watched():
        last = w.get("last_checked")
        overdue = False
        if last:
            try:
                overdue = datetime.now() - datetime.fromisoformat(last) > timedelta(minutes=watcher.CYCLE_MINUTES * 4)
            except ValueError:
                pass
        c = counts.get(w["username"], {})
        out.append({**w, "media_count": c.get("n", 0), "last_download_at": c.get("last"), "watcher_running": not overdue})
    return {"watched": out}


@router.delete("/api/watch/{username}")
async def remove_watch(username: str):
    await db.remove_watched(username)
    await db.add_log("감시 삭제", f"@{username}")
    return {"ok": True}


@router.post("/api/watch/{username}/run")
async def run_watch(username: str):
    acc = next((w for w in await db.get_watched() if w["username"] == username), None)
    if not acc:
        raise HTTPException(404, "감시 계정을 찾을 수 없습니다")
    n = await watcher.check_account(username, acc.get("last_tweet_id") or None, dlqueue.enqueue)
    await db.add_log("감시 실행", f"@{username} → {n}건")
    return {"ok": True, "new_downloads": n}


# ─── likes ───
@router.get("/api/likes/status")
async def likes_status():
    return {**(await db.get_likes_watch_state()), "x_username": await db.get_setting("x_username")}


@router.post("/api/likes/watch")
async def likes_toggle():
    state = await db.get_likes_watch_state()
    enable = not state["enabled"]
    if enable:
        x_user = await db.get_setting("x_username")
        if not x_user:
            raise HTTPException(400, "설정에서 X 계정 이름을 먼저 입력하세요")
        if not state["last_tweet_id"]:
            likes = await list_user_likes(x_user, limit=1)
            if likes:
                await db.update_likes_watch_state(last_tweet_id=likes[0]["id"])
    await db.update_likes_watch_state(enabled=enable)
    await db.add_log("좋아요 감시", "켜짐" if enable else "꺼짐")
    return {"ok": True, "enabled": enable}


@router.post("/api/likes/import")
async def likes_import():
    x_user = await db.get_setting("x_username")
    if not x_user:
        raise HTTPException(400, "설정에서 X 계정 이름을 먼저 입력하세요")
    likes = await list_user_likes(x_user, limit=200)
    imported = skipped = 0
    for l in likes:
        try:
            await dlqueue.enqueue(l["url"], None, "likes")
            imported += 1
        except ValueError:
            skipped += 1
    if likes:
        newest = max(likes, key=lambda l: int(l["id"]))["id"]
        await db.update_likes_watch_state(last_tweet_id=newest, last_checked=datetime.now().isoformat())
    await db.add_log("좋아요 가져오기", f"{imported}건 추가, {skipped}건 제외")
    return {"ok": True, "imported": imported, "skipped": skipped}


# ─── X login (cookies) ───
def _write_cookie(name: str, value: str | None):
    path = config.COOKIES_PATH
    lines = open(path).read().splitlines() if os.path.exists(path) else []
    keep = [l for l in lines if l and not l.startswith("#") and not (len(l.split("\t")) >= 7 and l.split("\t")[5] == name
                                                                      and l.split("\t")[0].endswith("x.com"))]
    if value:
        keep.append(f".x.com\tTRUE\t/\tTRUE\t0\t{name}\t{value}")
    with open(path, "w") as f:
        f.write("# Netscape HTTP Cookie File\n\n" + "\n".join(keep) + "\n")
    os.chmod(path, 0o600)


def _x_logged_in() -> bool:
    p = config.COOKIES_PATH
    return os.path.exists(p) and "auth_token" in open(p).read()


@router.get("/api/settings")
async def get_settings():
    return {"x_logged_in": _x_logged_in(), "x_username": await db.get_setting("x_username") or "",
            "app": config.APP_NAME}


class XLoginReq(BaseModel):
    auth_token: str
    ct0: str | None = None


@router.post("/api/settings/x_login")
async def x_login(req: XLoginReq):
    _write_cookie("auth_token", req.auth_token.strip())
    if req.ct0:
        _write_cookie("ct0", req.ct0.strip())
    info = await extract_info("https://x.com/X/status/1445078208190291973")
    if not info:
        _write_cookie("auth_token", None)
        raise HTTPException(400, "auth_token이 유효하지 않습니다")
    return {"ok": True}


@router.post("/api/settings/x_logout")
async def x_logout():
    _write_cookie("auth_token", None)
    _write_cookie("ct0", None)
    return {"ok": True}


class XUserReq(BaseModel):
    x_username: str


@router.put("/api/settings/x_username")
async def x_username(req: XUserReq):
    await db.set_setting("x_username", req.x_username.strip().lstrip("@"))
    return {"ok": True}


@router.get("/api/logs")
async def logs(limit: int = 50):
    return {"logs": await db.get_logs(min(limit, 300))}


# ─── stats ───
@router.get("/api/stats")
async def stats():
    async with db.connect() as conn:
        cur = await conn.execute("SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS s, "
                                 "SUM(kind = 'video') AS v, SUM(kind = 'image') AS i FROM media WHERE deleted = 0")
        tot = dict(await cur.fetchone())
        cats = await library.load_categories(conn)
        by_axis = []
        for k in library.AXIS_KEYS:
            cur = await conn.execute(f"SELECT {k} AS cid, COUNT(*) AS n, SUM(size) AS s FROM media "
                                     f"WHERE deleted = 0 GROUP BY {k} ORDER BY s DESC")
            by_axis.append([{"id": r["cid"], "name": cats[r["cid"]]["name"] if r["cid"] in cats else "미분류",
                             "count": r["n"], "size_bytes": r["s"] or 0} for r in await cur.fetchall()])
        cur = await conn.execute("SELECT source, COUNT(*) AS n, SUM(size) AS s FROM media WHERE deleted = 0 GROUP BY source")
        by_source = [{"source": r["source"], "count": r["n"], "size_bytes": r["s"] or 0} for r in await cur.fetchall()]
        cur = await conn.execute("SELECT watched_by AS name, COUNT(*) AS n, SUM(size) AS s FROM media WHERE deleted = 0 "
                                 "AND watched_by IS NOT NULL GROUP BY watched_by ORDER BY s DESC")
        by_watch = [{"name": r["name"], "count": r["n"], "size_bytes": r["s"] or 0} for r in await cur.fetchall()]
        cur = await conn.execute("SELECT substr(added_at, 1, 10) AS d, COUNT(*) AS n FROM media WHERE deleted = 0 "
                                 "AND added_at >= ? GROUP BY d ORDER BY d", ((datetime.now() - timedelta(days=30)).date().isoformat(),))
        daily = [{"date": r["d"], "count": r["n"]} for r in await cur.fetchall()]
    disk = await asyncio.to_thread(_disk)
    return {"total_files": tot["n"], "total_size_bytes": tot["s"], "videos": tot["v"] or 0, "images": tot["i"] or 0,
            "axes": await library.axis_names(), "by_axis": by_axis, "by_source": by_source, "by_watch": by_watch,
            "daily": daily, "disk": disk}


def _disk():
    try:
        st = os.statvfs(config.LIBRARY_ROOT)
        return {"total": st.f_blocks * st.f_frsize, "free": st.f_bavail * st.f_frsize}
    except OSError:
        return None
