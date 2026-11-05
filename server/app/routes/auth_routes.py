from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel

from app import auth, config

router = APIRouter()


def _ua_name(ua: str) -> str:
    device = next((d for k, d in (("iPad", "iPad"), ("iPhone", "iPhone"), ("Android", "Android"), ("Macintosh", "Mac"),
                                  ("Windows", "Windows"), ("Linux", "Linux")) if k in ua), "기기")
    browser = next((b for k, b in (("Edg/", "Edge"), ("CriOS", "Chrome"), ("Chrome/", "Chrome"), ("Firefox", "Firefox"),
                                   ("Safari", "Safari")) if k in ua), "브라우저")
    return f"{device} {browser}"


class LoginRequest(BaseModel):
    username: str
    password: str
    client: str = "web"   # web | app
    device: str | None = None


async def _login(req: LoginRequest, request: Request, response: Response):
    ip = auth.client_ip(request)
    await auth.check_throttle(ip)
    if not auth.credentials_ok(req.username, req.password):
        await auth.record_failure(ip)
        raise HTTPException(401, "아이디 또는 비밀번호가 올바르지 않습니다")
    await auth.clear_failures(ip)
    if req.client == "app":
        token = await auth.create_session("app", (req.device or "앱")[:60])
        return {"ok": True, "token": token}
    token = await auth.create_session("web", _ua_name(request.headers.get("user-agent") or ""))
    response.set_cookie(auth.COOKIE, token, httponly=True, secure=True, samesite="lax",
                        max_age=86400 * config.WEB_SESSION_DAYS)
    return {"ok": True}


@router.post("/api/auth/login")
async def login(req: LoginRequest, request: Request, response: Response):
    return await _login(req, request, response)


@router.post("/api/auth/logout")
async def logout(request: Request, response: Response):
    token, _ = auth._extract_token(request.headers, request.query_params, request.cookies)
    if token:
        await auth.revoke(token)
    response.delete_cookie(auth.COOKIE)
    return {"ok": True}


@router.get("/api/auth/check")
async def check(request: Request):
    return {"authenticated": await auth.is_authorized(request.headers, request.query_params, request.cookies),
            "app": config.APP_NAME}


@router.get("/api/auth/devices", dependencies=[Depends(auth.require_auth)])
async def devices():
    return {"devices": await auth.list_devices()}


@router.delete("/api/auth/devices/{short_id}", dependencies=[Depends(auth.require_auth)])
async def revoke_device(short_id: str):
    await auth.revoke_device(short_id)
    return {"ok": True}
