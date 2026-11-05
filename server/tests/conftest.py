import os
import subprocess

import httpx
import pytest
import pytest_asyncio


@pytest.fixture()
def env(tmp_path, monkeypatch):
    lib = tmp_path / "lib"
    data = tmp_path / "data"
    lib.mkdir()
    data.mkdir()
    from app import config
    monkeypatch.setattr(config, "LIBRARY_ROOT", str(lib))
    monkeypatch.setattr(config, "DATA_DIR", str(data))
    monkeypatch.setattr(config, "DB_PATH", str(data / "t.db"))
    monkeypatch.setattr(config, "THUMB_DIR", str(data / "thumbs"))
    monkeypatch.setattr(config, "COOKIES_PATH", str(data / "cookies.txt"))
    monkeypatch.setattr(config, "AUTH_USER", "tester")
    monkeypatch.setattr(config, "AUTH_PASS", "pw-test-123")
    monkeypatch.setattr(config, "API_KEY", "")
    monkeypatch.setenv("MOABOM_BACKGROUND", "0")
    return lib


def make(lib, rel, content=b"x", video=False):
    p = lib / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    if video:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10",
                        "-t", "1", "-pix_fmt", "yuv420p", str(p)], check=True)
    else:
        p.write_bytes(content)
    return p


@pytest_asyncio.fixture()
async def client(env):
    from app import db
    from app.main import app
    await db.init_db()
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="https://test") as c:
        r = await c.post("/api/auth/login", json={"username": "tester", "password": "pw-test-123", "client": "app",
                                                  "device": "pytest"})
        assert r.status_code == 200, r.text
        c.headers["Authorization"] = f"Bearer {r.json()['token']}"
        yield c
