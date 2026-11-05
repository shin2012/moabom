"""Optional X helpers (auto-like after download, account status). Disabled unless MOABOM_X_BEARER is set."""
import json
import logging
import re
import urllib.parse

import httpx

from app import config

logger = logging.getLogger("moabom.xapi")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"


def _cookies() -> tuple[str | None, str | None]:
    auth_token = ct0 = None
    try:
        with open(config.COOKIES_PATH) as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) >= 7:
                    if parts[5] == "auth_token":
                        auth_token = parts[6]
                    elif parts[5] == "ct0":
                        ct0 = parts[6]
    except OSError:
        pass
    return auth_token, ct0


def _headers() -> dict | None:
    if not config.X_WEB_BEARER:
        return None
    auth_token, ct0 = _cookies()
    if not auth_token or not ct0:
        return None
    return {"authorization": f"Bearer {config.X_WEB_BEARER}", "cookie": f"auth_token={auth_token}; ct0={ct0}",
            "x-csrf-token": ct0, "content-type": "application/json", "x-twitter-active-user": "yes",
            "x-twitter-auth-type": "OAuth2Session", "user-agent": UA}


async def like_tweet(url: str) -> bool:
    m = re.search(r"(?:twitter\.com|x\.com)/\w+/status/(\d+)", url)
    headers = _headers()
    if not m or not headers:
        return False
    qid = "lI07N6Otwv1PhnEgXILM7A"
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            r = await client.post(f"https://x.com/i/api/graphql/{qid}/FavoriteTweet", headers=headers,
                                  json={"variables": {"tweet_id": m.group(1)}, "queryId": qid})
            return r.status_code == 200
    except Exception as e:
        logger.debug(f"like error: {e}")
        return False


async def account_status(username: str) -> str:
    headers = _headers()
    if not headers:
        return "unknown"
    params = urllib.parse.urlencode({"variables": json.dumps({"screen_name": username}),
                                     "features": json.dumps({"hidden_profile_subscriptions_enabled": True})})
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.get(f"https://x.com/i/api/graphql/xc8f1g7BYqr6VTzTbvNlGw/UserByScreenName?{params}",
                                 headers=headers)
            if r.status_code != 200:
                return "error"
            user = r.json().get("data", {}).get("user", {}).get("result", {})
            if not user:
                return "not_found"
            if user.get("__typename") == "User":
                return "active"
            if user.get("__typename") == "UserUnavailable":
                return "suspended" if "suspend" in (user.get("reason") or "").lower() else "unavailable"
            return "unknown"
    except Exception:
        return "error"
