"""Authentication: web session cookie, app bearer tokens, optional static API key, login throttling."""
import hashlib
import hmac
import secrets
import time
from datetime import datetime, timedelta

from fastapi import HTTPException, Request, WebSocket

from app import config, db

COOKIE = "moabom_session"


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def credentials_ok(username: str, password: str) -> bool:
    if not config.AUTH_USER or not config.AUTH_PASS:
        return False
    u = hmac.compare_digest(username.encode(), config.AUTH_USER.encode())
    p = hmac.compare_digest(password.encode(), config.AUTH_PASS.encode())
    return u and p


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "?"


async def check_throttle(ip: str):
    cutoff = time.time() - config.LOGIN_WINDOW_SECONDS
    async with db.connect() as conn:
        await conn.execute("DELETE FROM login_failures WHERE at < ?", (cutoff,))
        cur = await conn.execute("SELECT COUNT(*) AS n FROM login_failures WHERE ip = ?", (ip,))
        n = (await cur.fetchone())["n"]
        await conn.commit()
    if n >= config.LOGIN_MAX_FAILURES:
        raise HTTPException(429, "로그인 시도가 너무 많습니다. 잠시 후 다시 시도하세요")


async def record_failure(ip: str):
    async with db.connect() as conn:
        await conn.execute("INSERT INTO login_failures (ip, at) VALUES (?, ?)", (ip, time.time()))
        await conn.commit()


async def clear_failures(ip: str):
    async with db.connect() as conn:
        await conn.execute("DELETE FROM login_failures WHERE ip = ?", (ip,))
        await conn.commit()


async def create_session(kind: str, name: str | None = None) -> str:
    token = secrets.token_urlsafe(32)
    now = datetime.now()
    expires = (now + timedelta(days=config.WEB_SESSION_DAYS)).isoformat() if kind == "web" else None
    async with db.connect() as conn:
        await conn.execute("INSERT INTO sessions (token_hash, kind, name, created_at, last_used, expires_at) "
                           "VALUES (?, ?, ?, ?, ?, ?)", (_hash(token), kind, name, now.isoformat(), now.isoformat(), expires))
        await conn.commit()
    return token


async def revoke(token: str):
    async with db.connect() as conn:
        await conn.execute("DELETE FROM sessions WHERE token_hash = ?", (_hash(token),))
        await conn.commit()


async def _valid_token(token: str | None) -> dict | None:
    if not token:
        return None
    async with db.connect() as conn:
        cur = await conn.execute("SELECT * FROM sessions WHERE token_hash = ?", (_hash(token),))
        row = await cur.fetchone()
        if not row:
            return None
        row = dict(row)
        now = datetime.now()
        if row["expires_at"] and datetime.fromisoformat(row["expires_at"]) < now:
            await conn.execute("DELETE FROM sessions WHERE token_hash = ?", (row["token_hash"],))
            await conn.commit()
            return None
        last = datetime.fromisoformat(row["last_used"]) if row["last_used"] else None
        if not last or now - last > timedelta(minutes=10):
            upd = [now.isoformat()]
            q = "UPDATE sessions SET last_used = ?"
            if row["kind"] == "web":  # sliding expiry
                q += ", expires_at = ?"
                upd.append((now + timedelta(days=config.WEB_SESSION_DAYS)).isoformat())
            await conn.execute(q + " WHERE token_hash = ?", (*upd, row["token_hash"]))
            await conn.commit()
        return row


def _extract_token(headers, query, cookies) -> tuple[str | None, str | None]:
    authz = headers.get("authorization") or ""
    bearer = authz[7:].strip() if authz.lower().startswith("bearer ") else None
    return bearer or query.get("token") or cookies.get(COOKIE), headers.get("x-api-key") or query.get("api_key")


async def is_authorized(headers, query, cookies) -> bool:
    token, api_key = _extract_token(headers, query, cookies)
    if api_key and config.API_KEY and hmac.compare_digest(api_key, config.API_KEY):
        return True
    return await _valid_token(token) is not None


async def require_auth(request: Request):
    if await is_authorized(request.headers, request.query_params, request.cookies):
        return True
    raise HTTPException(401, "인증이 필요합니다")


async def ws_authorized(ws: WebSocket) -> bool:
    return await is_authorized(ws.headers, ws.query_params, ws.cookies)


async def list_devices() -> list[dict]:
    async with db.connect() as conn:
        cur = await conn.execute("SELECT substr(token_hash, 1, 12) AS id, kind, name, created_at, last_used "
                                 "FROM sessions ORDER BY last_used DESC")
        return [dict(r) for r in await cur.fetchall()]


async def revoke_device(short_id: str):
    async with db.connect() as conn:
        await conn.execute("DELETE FROM sessions WHERE substr(token_hash, 1, 12) = ?", (short_id,))
        await conn.commit()
