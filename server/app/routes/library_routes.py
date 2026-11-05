import os
import random
import re

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse, Response, StreamingResponse
from pydantic import BaseModel

from app import auth, config, db, events, library

router = APIRouter(dependencies=[Depends(auth.require_auth)])

CONTENT_TYPES = {".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/quicktime", ".webm": "video/webm",
                 ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".webp": "image/webp",
                 ".gif": "image/gif"}


@router.get("/api/sync")
async def sync(since: int = 0, limit: int = 2000):
    """Change feed for offline-first clients: rows with rev > since (deleted rows included as tombstones)."""
    return await library.changes(since, max(100, min(limit, 5000)))


def _cat_filter(col: str, value: str | None, where: list, args: list):
    if value is None or value == "":
        return
    if value == "none":
        where.append(f"{col} IS NULL")
    else:
        where.append(f"{col} = ?")
        args.append(int(value))


@router.get("/api/media")
async def list_media(c1: str | None = None, c2: str | None = None, c3: str | None = None, source: str | None = None,
                     owner: str | None = None, kind: str | None = None, favorite: bool = False, q: str | None = None,
                     sort: str = "new", seed: int | None = None, offset: int = 0, limit: int = 60):
    where, args = ["deleted = 0"], []
    _cat_filter("c1", c1, where, args)
    _cat_filter("c2", c2, where, args)
    _cat_filter("c3", c3, where, args)
    if source:
        where.append("source = ?")
        args.append(source)
    if owner:
        owners = [o for o in owner.split(",") if o]
        where.append(f"(owner IN ({','.join('?' * len(owners))}) OR watched_by IN ({','.join('?' * len(owners))}))")
        args += owners + owners
    if kind in ("video", "image"):
        where.append("kind = ?")
        args.append(kind)
    if favorite:
        where.append("favorite = 1")
    if q:
        where.append("(title LIKE ? OR owner LIKE ? OR path LIKE ?)")
        args += [f"%{q}%"] * 3
    limit = max(1, min(limit, 500))
    sql_where = " AND ".join(where)
    async with db.connect() as conn:
        cur = await conn.execute(f"SELECT COUNT(*) AS n FROM media WHERE {sql_where}", args)
        total = (await cur.fetchone())["n"]
        if sort == "random":
            cur = await conn.execute(f"SELECT id FROM media WHERE {sql_where}", args)
            ids = [r["id"] for r in await cur.fetchall()]
            seed = seed if seed is not None else random.randint(1, 10**9)
            random.Random(seed).shuffle(ids)
            page = ids[offset:offset + limit]
            rows = {r["id"]: r for r in await library.get_media(page)}
            items = [rows[i] for i in page if i in rows]
        else:
            order = "added_at ASC, id ASC" if sort == "old" else "added_at DESC, id DESC"
            cur = await conn.execute(f"SELECT * FROM media WHERE {sql_where} ORDER BY {order} LIMIT ? OFFSET ?",
                                     [*args, limit, offset])
            items = [dict(r) for r in await cur.fetchall()]
    return {"items": [library.media_out(i) for i in items], "total": total, "offset": offset,
            "has_more": offset + len(items) < total, "seed": seed}


@router.get("/api/owners")
async def owners():
    async with db.connect() as conn:
        cur = await conn.execute("SELECT COALESCE(watched_by, owner) AS name, COUNT(*) AS count FROM media "
                                 "WHERE deleted = 0 AND COALESCE(watched_by, owner) IS NOT NULL "
                                 "GROUP BY 1 ORDER BY count DESC")
        return {"owners": [dict(r) for r in await cur.fetchall()]}


async def _row(mid: int) -> dict:
    rows = await library.get_media([mid])
    if not rows or rows[0]["deleted"]:
        raise HTTPException(404, "파일을 찾을 수 없습니다")
    return rows[0]


@router.get("/api/media/{mid}/file")
async def media_file(mid: int, request: Request):
    row = await _row(mid)
    path = os.path.join(config.LIBRARY_ROOT, row["path"])
    if not os.path.isfile(path):
        raise HTTPException(404, "파일을 찾을 수 없습니다")
    return _ranged_file(path, request)


@router.get("/api/media/{mid}/thumb")
async def media_thumb(mid: int, w: int = 480):
    row = await _row(mid)
    out = await library.thumbnail(row, w)
    if not out:
        raise HTTPException(404, "썸네일을 만들 수 없습니다")
    return FileResponse(out, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=31536000, immutable"})


def _ranged_file(path: str, request: Request):
    size = os.path.getsize(path)
    ctype = CONTENT_TYPES.get(os.path.splitext(path)[1].lower(), "application/octet-stream")
    headers = {"Accept-Ranges": "bytes", "Cache-Control": "private, max-age=86400"}
    rng = request.headers.get("range")
    m = re.match(r"bytes=(\d*)-(\d*)", rng or "")
    if not m or (not m.group(1) and not m.group(2)):
        return FileResponse(path, media_type=ctype, headers=headers)
    if m.group(1):
        start = int(m.group(1))
        end = int(m.group(2)) if m.group(2) else size - 1
    else:  # suffix range: last N bytes
        start, end = max(0, size - int(m.group(2))), size - 1
    end = min(end, size - 1)
    if start > end or start >= size:
        return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
    length = end - start + 1

    def stream():
        with open(path, "rb") as f:
            f.seek(start)
            left = length
            while left > 0:
                chunk = f.read(min(512 * 1024, left))
                if not chunk:
                    break
                left -= len(chunk)
                yield chunk

    headers.update({"Content-Range": f"bytes {start}-{end}/{size}", "Content-Length": str(length)})
    return StreamingResponse(stream(), status_code=206, headers=headers, media_type=ctype)


class ClassifyRequest(BaseModel):
    ids: list[int]
    c1: int | None = None
    c2: int | None = None
    c3: int | None = None


@router.post("/api/media/classify")
async def classify(req: ClassifyRequest):
    """Only the axes present in the body change; send null to clear an axis. Files move on the NAS."""
    updates = {k: getattr(req, k) for k in ("c1", "c2", "c3") if k in req.model_fields_set}
    if not updates:
        raise HTTPException(400, "바꿀 분류가 없습니다")
    try:
        undo = await library.classify(req.ids, updates)
    except ValueError as e:
        raise HTTPException(400, str(e))
    await db.add_log("분류 변경", f"{len(undo)}개")
    await events.broadcast({"type": "library", "changed": req.ids})
    return {"ok": True, "moved": len(undo), "undo": undo, "items": [library.media_out(r) for r in await library.get_media(req.ids)]}


class UndoRequest(BaseModel):
    undo: list[dict]


@router.post("/api/media/undo")
async def undo(req: UndoRequest):
    await library.restore_classification(req.undo)
    ids = [u["id"] for u in req.undo]
    await events.broadcast({"type": "library", "changed": ids})
    return {"ok": True, "items": [library.media_out(r) for r in await library.get_media(ids)]}


class IdsRequest(BaseModel):
    ids: list[int]
    value: bool = True


@router.post("/api/media/delete")
async def delete(req: IdsRequest):
    n = await library.delete_media(req.ids)
    await db.add_log("삭제", f"{n}개")
    await events.broadcast({"type": "library", "changed": req.ids})
    return {"ok": True, "deleted": n}


@router.post("/api/media/favorite")
async def favorite(req: IdsRequest):
    await library.set_favorite(req.ids, req.value)
    return {"ok": True}


@router.post("/api/library/rescan")
async def rescan():
    return {"ok": True, **(await library.reconcile())}
