from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import auth, db, dlqueue, events

router = APIRouter(dependencies=[Depends(auth.require_auth)])


class DownloadReq(BaseModel):
    url: str
    c1: int | None = None
    c2: int | None = None
    c3: int | None = None
    use_defaults: bool = True


@router.post("/api/download")
async def add(req: DownloadReq):
    cats = {"c1": req.c1, "c2": req.c2, "c3": req.c3}
    if req.use_defaults and not any(cats.values()) and not req.model_fields_set & {"c1", "c2", "c3"}:
        for k in cats:
            v = await db.get_setting(f"default_{k}")
            cats[k] = int(v) if v and v.isdigit() else None
    try:
        did = await dlqueue.enqueue(req.url, cats)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True, "id": did}


@router.get("/api/downloads")
async def list_downloads(limit: int = 200):
    rows = await db.get_downloads(min(limit, 1000))
    return {"downloads": rows, "active": sum(1 for r in rows if r["status"] in ("queued", "downloading"))}


@router.get("/api/download/{did}")
async def get(did: int):
    dl = await db.get_download(did)
    if not dl:
        raise HTTPException(404, "다운로드를 찾을 수 없습니다")
    return dl


@router.post("/api/download/{did}/retry")
async def retry(did: int):
    dl = await db.get_download(did)
    if not dl:
        raise HTTPException(404, "다운로드를 찾을 수 없습니다")
    if dl["status"] not in ("failed", "cancelled"):
        raise HTTPException(400, "실패하거나 취소한 항목만 다시 시도할 수 있습니다")
    await db.update_download(did, status="queued", progress=0, error=None)
    await dlqueue.queue.put(did)
    await events.broadcast({"type": "status", "id": did, "status": "queued", "progress": 0})
    return {"ok": True}


@router.post("/api/download/{did}/cancel")
async def cancel(did: int):
    dl = await db.get_download(did)
    if not dl:
        raise HTTPException(404, "다운로드를 찾을 수 없습니다")
    if dl["status"] not in ("queued", "downloading"):
        raise HTTPException(400, "대기 중이거나 받는 중인 항목만 취소할 수 있습니다")
    await db.update_download(did, status="cancelled", error="취소함")
    await events.broadcast({"type": "status", "id": did, "status": "cancelled"})
    return {"ok": True}


@router.delete("/api/download/{did}")
async def remove(did: int):
    dl = await db.get_download(did)
    if not dl:
        raise HTTPException(404, "다운로드를 찾을 수 없습니다")
    if dl["status"] == "downloading":
        raise HTTPException(400, "받는 중인 항목은 먼저 취소하세요")
    await db.delete_download(did)
    await events.broadcast({"type": "deleted", "id": did})
    return {"ok": True}


@router.delete("/api/downloads/{status}")
async def clear(status: str):
    targets = {"completed": ["completed"], "failed": ["failed", "cancelled"],
               "all": ["completed", "failed", "cancelled"]}.get(status)
    if not targets:
        raise HTTPException(400, "잘못된 상태")
    n = 0
    for s in targets:
        n += await db.delete_downloads_by_status(s)
    await events.broadcast({"type": "cleared", "status": status, "count": n})
    return {"ok": True, "count": n}
