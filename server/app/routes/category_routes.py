from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import auth, db, events, library

router = APIRouter(dependencies=[Depends(auth.require_auth)])


async def categories_payload() -> dict:
    async with db.connect() as conn:
        cats = await library.load_categories(conn)
        counts = {}
        for k in library.AXIS_KEYS:
            cur = await conn.execute(f"SELECT {k} AS cid, COUNT(*) AS n FROM media WHERE deleted = 0 AND {k} IS NOT NULL GROUP BY {k}")
            for r in await cur.fetchall():
                counts[r["cid"]] = r["n"]
    items = sorted(({"id": c["id"], "axis": c["axis"], "name": c["name"], "sort": c["sort"],
                     "count": counts.get(c["id"], 0)} for c in cats.values()), key=lambda c: (c["axis"], c["sort"], c["name"]))
    defaults = {k: await _default(k, cats) for k in library.AXIS_KEYS}
    return {"axes": await library.axis_names(), "items": items, "defaults": defaults}


async def _default(key: str, cats: dict) -> int | None:
    v = await db.get_setting(f"default_{key}")
    return int(v) if v and v.isdigit() and int(v) in cats else None


@router.get("/api/categories")
async def get_categories():
    return await categories_payload()


class CreateReq(BaseModel):
    axis: int
    name: str


@router.post("/api/categories")
async def create(req: CreateReq):
    try:
        c = await library.create_category(req.axis, req.name)
    except ValueError as e:
        raise HTTPException(400, str(e))
    await events.broadcast({"type": "categories"})
    return {"ok": True, "category": c}


class RenameReq(BaseModel):
    name: str


@router.patch("/api/categories/{cid}")
async def rename(cid: int, req: RenameReq):
    try:
        moved = await library.rename_category(cid, req.name)
    except ValueError as e:
        raise HTTPException(400, str(e))
    await db.add_log("분류 이름 변경", f"#{cid} → {req.name} ({moved}개 이동)")
    await events.broadcast({"type": "categories"})
    return {"ok": True, "moved": moved}


class MergeReq(BaseModel):
    into: int


@router.post("/api/categories/{cid}/merge")
async def merge(cid: int, req: MergeReq):
    try:
        moved = await library.merge_category(cid, req.into)
    except ValueError as e:
        raise HTTPException(400, str(e))
    await db.add_log("분류 합치기", f"#{cid} → #{req.into} ({moved}개 이동)")
    await events.broadcast({"type": "categories"})
    return {"ok": True, "moved": moved}


@router.delete("/api/categories/{cid}")
async def delete(cid: int):
    try:
        moved = await library.delete_category(cid)
    except ValueError as e:
        raise HTTPException(400, str(e))
    await db.add_log("분류 삭제", f"#{cid} ({moved}개 이동)")
    await events.broadcast({"type": "categories"})
    return {"ok": True, "moved": moved}


class ReorderReq(BaseModel):
    axis: int
    ids: list[int]


@router.post("/api/categories/reorder")
async def reorder(req: ReorderReq):
    await library.reorder_categories(req.axis, req.ids)
    await events.broadcast({"type": "categories"})
    return {"ok": True}


class AxesReq(BaseModel):
    names: list[str]


@router.put("/api/categories/axes")
async def axes(req: AxesReq):
    await library.set_axis_names(req.names)
    await events.broadcast({"type": "categories"})
    return {"ok": True, "axes": await library.axis_names()}


class DefaultsReq(BaseModel):
    c1: int | None = None
    c2: int | None = None
    c3: int | None = None


@router.put("/api/categories/defaults")
async def defaults(req: DefaultsReq):
    for k in library.AXIS_KEYS:
        v = getattr(req, k)
        await db.set_setting(f"default_{k}", str(v) if v else "")
    return {"ok": True}
