import asyncio

import pytest

from app import db, watcher
from app.routes import misc_routes


async def _no_posts(*a, **k):
    return []


@pytest.mark.asyncio
async def test_cleanup_removes_only_unavailable(client, env, monkeypatch):
    monkeypatch.setattr(misc_routes, "list_user_media", _no_posts)
    for name in ("ok_one", "gone_one", "gone_two", "unknown_one"):
        await client.post("/api/watch", json={"username": name})
    await db.update_account_status("ok_one", "active")
    await db.update_account_status("gone_one", "suspended")
    await db.update_account_status("gone_two", "not_found")
    await db.update_account_status("unknown_one", "error")
    r = (await client.post("/api/watch/cleanup")).json()
    assert sorted(r["removed"]) == ["gone_one", "gone_two"]
    names = sorted(w["username"] for w in (await client.get("/api/watch")).json()["watched"])
    assert names == ["ok_one", "unknown_one"]


@pytest.mark.asyncio
async def test_backfill_queues_whole_timeline(client, env, monkeypatch):
    monkeypatch.setattr(misc_routes, "list_user_media", _no_posts)
    await client.post("/api/watch", json={"username": "Full_Acc"})
    posts = [
        {"url": "https://x.com/Full_Acc/status/30", "id": "30", "title": "", "has_video": True},
        {"url": "https://x.com/Full_Acc/status/20", "id": "20", "title": "", "has_video": False},
        {"url": "https://x.com/Full_Acc/status/10", "id": "10", "title": "", "has_video": True},
    ]
    seen_args = {}

    async def fake_list(username, limit=50, timeout=180):
        seen_args.update(username=username, limit=limit)
        return posts
    monkeypatch.setattr(watcher, "list_user_media", fake_list)
    await db.mark_url_downloaded("https://x.com/full_acc/status/10", "10", "full_acc")
    queued = []

    async def fake_enqueue(url, cats=None, source="manual", watched_by=None):
        queued.append((url, source, watched_by))
        return len(queued)

    n = await watcher.backfill_account("Full_Acc", True, fake_enqueue)
    assert seen_args == {"username": "Full_Acc", "limit": None}
    assert n == 1 and queued == [("https://x.com/Full_Acc/status/30", "watch", "Full_Acc")]
    assert (await db.find_watched("full_acc"))["last_tweet_id"] == "30"
    assert watcher.backfills == {}

    queued.clear()
    assert await watcher.backfill_account("Full_Acc", False, fake_enqueue) == 2
    assert [q[0].rsplit("/", 1)[1] for q in queued] == ["30", "20"]


@pytest.mark.asyncio
async def test_backfill_route_starts_once(client, env, monkeypatch):
    monkeypatch.setattr(misc_routes, "list_user_media", _no_posts)
    await client.post("/api/watch", json={"username": "slow_acc"})
    gate = asyncio.Event()

    async def slow_list(*a, **k):
        await gate.wait()
        return []
    monkeypatch.setattr(watcher, "list_user_media", slow_list)
    r = (await client.post("/api/watch/SLOW_ACC/all", json={"videos_only": True})).json()
    assert r["started"] is True
    r = (await client.post("/api/watch/slow_acc/all")).json()
    assert r["started"] is False and r["running"] is True
    w = (await client.get("/api/watch")).json()["watched"][0]
    assert w["backfill"]["videos_only"] is True
    gate.set()
    for _ in range(50):
        if not watcher.backfills:
            break
        await asyncio.sleep(0.01)
    assert watcher.backfills == {}
    assert (await client.post("/api/watch/nobody/all")).status_code == 404
