import os

import httpx
import pytest

from tests.conftest import make

pytestmark = pytest.mark.asyncio


async def _sync(c):
    r = await c.get("/api/sync", params={"since": 0})
    assert r.status_code == 200
    return r.json()


async def test_auth_required_and_throttle(env):
    from app import db
    from app.main import app
    await db.init_db()
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://t") as c:
        assert (await c.get("/api/sync")).status_code == 401
        assert (await c.get("/api/sync", headers={"Authorization": "Bearer nope"})).status_code == 401
        for _ in range(5):
            r = await c.post("/api/auth/login", json={"username": "tester", "password": "bad"})
            assert r.status_code == 401
        r = await c.post("/api/auth/login", json={"username": "tester", "password": "pw-test-123"})
        assert r.status_code == 429


async def test_web_cookie_login(env):
    from app import db
    from app.main import app
    await db.init_db()
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://t") as c:
        r = await c.post("/api/auth/login", json={"username": "tester", "password": "pw-test-123"})
        assert r.status_code == 200 and "moabom_session" in r.cookies
        assert (await c.get("/api/auth/check")).json()["authenticated"] is True
        assert (await c.get("/api/categories")).status_code == 200
        await c.post("/api/auth/logout")
        c.cookies.clear()
        assert (await c.get("/api/categories")).status_code == 401


async def test_scan_builds_categories_and_pairs(client, env):
    make(env, "A1/B1/C1/user_20260101000000_001.mp4", video=True)
    make(env, "A1/B1/C1/user_20260101000000_001.jpg", b"jpg")
    make(env, "A2/B1/pic_20260101000000_001.png", b"png")
    make(env, "자동감시/@watcher1/watcher1_20260101000000_001.jpg", b"img")
    make(env, "root.jpg", b"r")
    r = await client.post("/api/library/rescan")
    assert r.json()["added"] == 4
    s = await _sync(client)
    media = {m["path"]: m for m in s["media"]}
    assert set(media) == {"A1/B1/C1/user_20260101000000_001.mp4", "A2/B1/pic_20260101000000_001.png",
                          "자동감시/@watcher1/watcher1_20260101000000_001.jpg", "root.jpg"}
    vid = media["A1/B1/C1/user_20260101000000_001.mp4"]
    assert vid["kind"] == "video" and vid["thumb"].endswith(".jpg") and vid["owner"] == "user"
    w = media["자동감시/@watcher1/watcher1_20260101000000_001.jpg"]
    assert w["source"] == "watch" and w["watched_by"] == "watcher1" and w["c1"] is None
    cats = {(c["axis"], c["name"]) for c in s["categories"]}
    assert cats == {(1, "A1"), (1, "A2"), (2, "B1"), (3, "C1")}
    # rescan is idempotent
    r = await client.post("/api/library/rescan")
    assert r.json() == {"ok": True, "added": 0, "moved": 0, "removed": 0, "updated": 0}


async def test_classify_moves_files_and_undo(client, env):
    make(env, "자동감시/@w/w_20260101000000_001.mp4", video=True)
    make(env, "자동감시/@w/w_20260101000000_001.jpg", b"t")
    await client.post("/api/library/rescan")
    s = await _sync(client)
    mid = s["media"][0]["id"]
    a = (await client.post("/api/categories", json={"axis": 1, "name": "Alpha/One"})).json()["category"]
    b = (await client.post("/api/categories", json={"axis": 3, "name": "Gamma"})).json()["category"]
    r = await client.post("/api/media/classify", json={"ids": [mid], "c1": a["id"], "c3": b["id"]})
    assert r.status_code == 200, r.text
    item = r.json()["items"][0]
    assert item["path"] == "Alpha_One/미분류/Gamma/w_20260101000000_001.mp4"
    assert (env / "Alpha_One/미분류/Gamma/w_20260101000000_001.jpg").exists()
    assert not (env / "자동감시").exists()  # emptied folders pruned
    # change only axis 3 -> keeps axis 1
    r = await client.post("/api/media/classify", json={"ids": [mid], "c3": None})
    assert r.json()["items"][0]["path"] == "Alpha_One/w_20260101000000_001.mp4"
    undo = r.json()["undo"]
    r = await client.post("/api/media/undo", json={"undo": undo})
    assert r.json()["items"][0]["path"] == "Alpha_One/미분류/Gamma/w_20260101000000_001.mp4"
    # clear everything -> back to the watch folder
    r = await client.post("/api/media/classify", json={"ids": [mid], "c1": None, "c3": None})
    assert r.json()["items"][0]["path"] == "자동감시/@w/w_20260101000000_001.mp4"
    # rescan after app moves sees no changes
    r = await client.post("/api/library/rescan")
    assert r.json()["added"] == r.json()["removed"] == 0


async def test_rename_merge_delete_category(client, env):
    make(env, "Old/x_20260101000000_001.jpg", b"1")
    make(env, "Other/y_20260101000000_001.jpg", b"2")
    await client.post("/api/library/rescan")
    cats = (await client.get("/api/categories")).json()["items"]
    old = next(c for c in cats if c["name"] == "Old")
    other = next(c for c in cats if c["name"] == "Other")
    assert old["count"] == 1
    r = await client.patch(f"/api/categories/{old['id']}", json={"name": "New"})
    assert r.json()["moved"] == 1
    assert (env / "New/x_20260101000000_001.jpg").exists() and not (env / "Old").exists()
    # rename collision is rejected
    assert (await client.patch(f"/api/categories/{old['id']}", json={"name": "Other"})).status_code == 400
    r = await client.post(f"/api/categories/{other['id']}/merge", json={"into": old["id"]})
    assert r.json()["moved"] == 1
    assert (env / "New/y_20260101000000_001.jpg").exists()
    cats = (await client.get("/api/categories")).json()["items"]
    assert [c["name"] for c in cats] == ["New"] and cats[0]["count"] == 2
    r = await client.delete(f"/api/categories/{old['id']}")
    assert r.json()["moved"] == 2
    assert (env / "미분류/x_20260101000000_001.jpg").exists()
    s = await _sync(client)
    assert all(m["c1"] is None for m in s["media"] if not m["deleted"])


async def test_name_collision_on_move_keeps_both(client, env):
    make(env, "A/same.jpg", b"1")
    make(env, "B/same.jpg", b"2")
    await client.post("/api/library/rescan")
    s = await _sync(client)
    cats = {c["name"]: c["id"] for c in s["categories"]}
    src = next(m for m in s["media"] if m["path"] == "A/same.jpg")
    r = await client.post("/api/media/classify", json={"ids": [src["id"]], "c1": cats["B"]})
    assert r.json()["items"][0]["path"] == "B/same_2.jpg"
    assert (env / "B/same.jpg").read_bytes() == b"2"


async def test_sync_incremental_and_delete(client, env):
    make(env, "A/a.jpg", b"1")
    make(env, "A/b.jpg", b"2")
    await client.post("/api/library/rescan")
    s = await _sync(client)
    rev = s["rev"]
    ids = {m["path"]: m["id"] for m in s["media"]}
    r = await client.post("/api/media/delete", json={"ids": [ids["A/a.jpg"]]})
    assert r.json()["deleted"] == 1
    d = (await client.get("/api/sync", params={"since": rev})).json()
    assert [m["id"] for m in d["media"]] == [ids["A/a.jpg"]] and d["media"][0]["deleted"] == 1
    assert d["rev"] > rev
    assert not (env / "A/a.jpg").exists()


async def test_sync_paging(client, env):
    for i in range(7):
        make(env, f"P/f{i}.jpg", bytes([i]))
    await client.post("/api/library/rescan")
    seen, since = [], 0
    while True:
        d = (await client.get("/api/sync", params={"since": since, "limit": 100})).json()
        seen += d["media"]
        since = d["rev"]
        if not d["has_more"]:
            break
    assert len({m["id"] for m in seen}) == 7


async def test_media_file_range_and_thumb(client, env):
    make(env, "V/v_20260101000000_001.mp4", video=True)
    await client.post("/api/library/rescan")
    mid = (await _sync(client))["media"][0]["id"]
    full = (env / "V/v_20260101000000_001.mp4").read_bytes()
    r = await client.get(f"/api/media/{mid}/file", headers={"Range": "bytes=10-19"})
    assert r.status_code == 206 and r.content == full[10:20]
    assert r.headers["content-range"] == f"bytes 10-19/{len(full)}"
    r = await client.get(f"/api/media/{mid}/thumb", params={"w": 240})
    assert r.status_code == 200 and r.content[:2] == b"\xff\xd8"
    # token in query works too (for players that cannot set headers)
    token = client.headers["Authorization"][7:]
    del client.headers["Authorization"]
    r = await client.get(f"/api/media/{mid}/file", params={"token": token}, headers={"Range": "bytes=0-1"})
    assert r.status_code == 206


async def test_probe_dimensions(client, env):
    from app import library
    make(env, "V/v.mp4", video=True)
    await client.post("/api/library/rescan")
    assert await library.probe_pending() == 1
    m = (await _sync(client))["media"][0]
    assert (m["width"], m["height"]) == (320, 240) and 0.5 < m["duration"] < 1.5


async def test_media_list_filters(client, env):
    make(env, "A/B/one.jpg", b"1")
    make(env, "A/two.jpg", b"2")
    make(env, "Z/three.jpg", b"3")
    await client.post("/api/library/rescan")
    cats = {c["name"]: c["id"] for c in (await client.get("/api/categories")).json()["items"]}
    r = (await client.get("/api/media", params={"c1": cats["A"]})).json()
    assert r["total"] == 2
    r = (await client.get("/api/media", params={"c1": cats["A"], "c2": "none"})).json()
    assert [i["path"] for i in r["items"]] == ["A/two.jpg"]
    r1 = (await client.get("/api/media", params={"sort": "random", "seed": 5})).json()
    r2 = (await client.get("/api/media", params={"sort": "random", "seed": 5})).json()
    assert [i["id"] for i in r1["items"]] == [i["id"] for i in r2["items"]]


async def test_external_move_keeps_id(client, env):
    make(env, "A/keep.jpg", b"12345")
    await client.post("/api/library/rescan")
    mid = (await _sync(client))["media"][0]["id"]
    os.makedirs(env / "B", exist_ok=True)
    os.replace(env / "A/keep.jpg", env / "B/keep.jpg")
    r = (await client.post("/api/library/rescan")).json()
    assert r["moved"] == 1 and r["removed"] == 0
    m = [m for m in (await _sync(client))["media"] if not m["deleted"]][0]
    assert m["id"] == mid and m["path"] == "B/keep.jpg"


async def test_axes_and_defaults(client, env):
    r = await client.put("/api/categories/axes", json={"names": ["첫째", "둘째", "셋째"]})
    assert r.json()["axes"] == ["첫째", "둘째", "셋째"]
    c = (await client.post("/api/categories", json={"axis": 2, "name": "기본"})).json()["category"]
    await client.put("/api/categories/defaults", json={"c2": c["id"]})
    assert (await client.get("/api/categories")).json()["defaults"]["c2"] == c["id"]
    assert (await client.post("/api/categories", json={"axis": 1, "name": "미분류"})).status_code == 400
