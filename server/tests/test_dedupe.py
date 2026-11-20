import aiosqlite
import pytest

from app import db, dlqueue
from app.routes import misc_routes


@pytest.mark.asyncio
async def test_post_dedupe_ignores_account_case(client, env):
    await db.mark_url_downloaded("https://x.com/SomeOne/status/111", "111", "SomeOne")
    assert await db.is_url_downloaded("https://x.com/someone/status/111", "111")
    assert await db.is_url_downloaded("https://x.com/SOMEONE/status/111")
    with pytest.raises(ValueError):
        await dlqueue.enqueue("https://x.com/someone/status/111?s=12")


@pytest.mark.asyncio
async def test_queue_dedupe_ignores_account_case(client, env, monkeypatch):
    did = await db.add_download("https://x.com/Abc/status/222", "222", "Abc", {})
    assert did
    assert await db.is_url_in_queue("https://x.com/abc/status/222", "222")


@pytest.mark.asyncio
async def test_watch_add_is_case_insensitive(client, env, monkeypatch):
    async def no_posts(*a, **k):
        return []
    monkeypatch.setattr(misc_routes, "list_user_media", no_posts)
    r = await client.post("/api/watch", json={"username": "@Watcher_One"})
    assert r.json() == {"ok": True, "username": "Watcher_One", "already": False}
    r = await client.post("/api/watch", json={"username": "https://x.com/watcher_one/status/123?s=12"})
    assert r.json()["already"] is True and r.json()["username"] == "Watcher_One"
    names = [w["username"] for w in (await client.get("/api/watch")).json()["watched"]]
    assert names == ["Watcher_One"]
    assert (await client.post("/api/watch", json={"username": "https://x.com/home"})).status_code == 400
    await client.delete("/api/watch/WATCHER_ONE")
    assert (await client.get("/api/watch")).json()["watched"] == []


def test_parse_watch_target():
    p = misc_routes.parse_watch_target
    assert p("abc_1") == "abc_1"
    assert p("https://twitter.com/Abc/status/1/photo/1") == "Abc"
    assert p("https://x.com/Abc?s=21") == "Abc"
    assert p("https://example.com/abc") is None


@pytest.mark.asyncio
async def test_migration_merges_case_duplicates(env):
    await db.init_db()
    async with aiosqlite.connect(str(env.parent / "data" / "t.db")) as conn:
        await conn.execute("DROP INDEX idx_watched_nocase")
        await conn.execute("INSERT INTO watched (username, last_tweet_id) VALUES ('Dup', '50'), ('dup', '90')")
        await conn.commit()
    await db.init_db()
    rows = await db.get_watched()
    assert [(r["username"], r["last_tweet_id"]) for r in rows] == [("dup", "90")]
