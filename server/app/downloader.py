"""Fetching media: gallery-dl first (X posts with images+videos), yt-dlp fallback / generic sites."""
import asyncio
import hashlib
import json
import logging
import os
import re
from datetime import datetime
from typing import Callable

from app import config

logger = logging.getLogger("moabom.downloader")

X_STATUS_RE = re.compile(r"https?://(?:www\.|mobile\.)?(?:twitter\.com|x\.com)/([^/?#]+)/status/(\d+)")
X_BROADCAST_RE = re.compile(r"https?://(?:www\.)?(?:twitter\.com|x\.com)/i/broadcasts/(\w+)")
HTTP_RE = re.compile(r"^https?://[^\s/$.?#].[^\s]*$", re.I)


def _cookies_args() -> list[str]:
    p = config.COOKIES_PATH
    return ["--cookies", p] if os.path.exists(p) and os.path.getsize(p) > 0 else []


def normalize_url(url: str) -> str:
    url = (url or "").strip()
    url = re.sub(r"https?://(?:www\.|mobile\.)?twitter\.com/", "https://x.com/", url)
    url = re.sub(r"https?://(?:www\.|mobile\.)x\.com/", "https://x.com/", url)
    m = X_STATUS_RE.match(url)
    if m:  # drop tracking params / photo suffixes
        url = f"https://x.com/{m.group(1)}/status/{m.group(2)}"
    return url


def validate_url(url: str) -> tuple[bool, str | None, str | None, str]:
    """Returns (valid, username, post_id, platform). platform: 'x' | 'web'."""
    m = X_STATUS_RE.match(url)
    if m:
        return True, m.group(1), m.group(2), "x"
    m = X_BROADCAST_RE.match(url)
    if m:
        return True, None, m.group(1), "x"
    if HTTP_RE.match(url):
        return True, None, hashlib.sha1(url.encode()).hexdigest()[:12], "web"
    return False, None, None, ""


def safe_name_part(value: str | None) -> str:
    value = (value or "unknown").lstrip("@").strip()
    value = re.sub(r"[^A-Za-z0-9_.-]+", "_", value)
    return value.strip("._-") or "unknown"


def _stamp(uploaded_at: str | None) -> str:
    if uploaded_at:
        try:
            return datetime.fromisoformat(uploaded_at.replace("Z", "+00:00")).strftime("%Y%m%d%H%M%S")
        except Exception:
            pass
    return datetime.now().strftime("%Y%m%d%H%M%S")


def _normalize_filenames(files: list[str], username: str, uploaded_at: str | None) -> list[str]:
    """Rename to {handle}_{yyyymmddHHMMSS}_{serial}.{ext}, keeping same-base pairs together."""
    stamp, handle = _stamp(uploaded_at), safe_name_part(username)
    by_base: dict[str, list[str]] = {}
    for p in sorted(files):
        by_base.setdefault(os.path.splitext(p)[0], []).append(p)
    out = []
    for serial, (_, group) in enumerate(sorted(by_base.items()), start=1):
        d = os.path.dirname(group[0])
        name = f"{handle}_{stamp}_{serial:03d}"
        dup = 2
        while any(os.path.exists(os.path.join(d, name + os.path.splitext(s)[1].lower())) and
                  os.path.join(d, name + os.path.splitext(s)[1].lower()) not in group for s in group):
            name = f"{handle}_{stamp}_{serial:03d}_{dup}"
            dup += 1
        for src in group:
            dst = os.path.join(d, name + os.path.splitext(src)[1].lower())
            if src != dst:
                os.replace(src, dst)
            out.append(dst)
    return out


async def _run(args: list[str], timeout: int) -> tuple[int, bytes, bytes]:
    proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise
    return proc.returncode, out, err


async def generate_thumbnail(video_path: str) -> str | None:
    thumb = os.path.splitext(video_path)[0] + ".jpg"
    if os.path.exists(thumb):
        return thumb
    try:
        code, _, _ = await _run(["ffmpeg", "-y", "-loglevel", "error", "-ss", "2", "-i", video_path, "-frames:v", "1",
                                 "-q:v", "3", "-vf", "scale='min(720,iw)':-2", thumb], 20)
        if code != 0 or not os.path.exists(thumb):
            code, _, _ = await _run(["ffmpeg", "-y", "-loglevel", "error", "-i", video_path, "-frames:v", "1",
                                     "-q:v", "3", "-vf", "scale='min(720,iw)':-2", thumb], 20)
        return thumb if os.path.exists(thumb) else None
    except Exception:
        return None


async def fix_faststart(files: list[str]):
    for path in files:
        if not path.lower().endswith(".mp4") or not os.path.exists(path):
            continue
        tmp = path + ".faststart.tmp.mp4"
        try:
            code, _, _ = await _run(["ffmpeg", "-y", "-loglevel", "error", "-i", path, "-c", "copy",
                                     "-movflags", "+faststart", tmp], 120)
            if code == 0 and os.path.exists(tmp) and os.path.getsize(tmp) > 0:
                os.replace(tmp, path)
        except Exception:
            pass
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)


async def extract_info(url: str) -> dict | None:
    try:
        code, out, _ = await _run(["yt-dlp", "--dump-json", "--no-download", "--no-cache-dir", "--no-playlist",
                                   *_cookies_args(), url], 45)
        if code == 0 and out:
            return json.loads(out.decode().strip().split("\n")[0])
    except Exception:
        pass
    return None


def _collect(out_dir: str, marker: str) -> list[str]:
    found = []
    for f in sorted(os.listdir(out_dir)) if os.path.isdir(out_dir) else []:
        if marker in f and not f.endswith((".part", ".tmp", ".ytdl")):
            found.append(os.path.join(out_dir, f))
    return found


async def download(url: str, out_dir: str, username: str, post_id: str, platform: str,
                   uploaded_at: str | None = None,
                   progress: Callable | None = None) -> tuple[bool, list[str], str | None]:
    """Download every media file of a post into out_dir (absolute). Returns (ok, files, error)."""
    os.makedirs(out_dir, exist_ok=True)
    marker = f"__{post_id}__"
    tmp_prefix = f"{safe_name_part(username)}{marker}"

    async def done(files):
        files = _normalize_filenames(files, username, uploaded_at)
        await fix_faststart(files)
        for f in list(files):
            if f.lower().endswith((".mp4", ".mov", ".m4v", ".webm")):
                t = await generate_thumbnail(f)
                if t and t not in files:
                    files.append(t)
        if progress:
            await progress(100.0)
        return True, files, None

    if platform == "x":
        if progress:
            await progress(20.0)
        try:
            await _run(["gallery-dl", *_cookies_args(), "--dest", out_dir, "--directory", "",
                        "--filename", tmp_prefix + "{num:02d}.{extension}", url], 180)
        except Exception as e:
            logger.info(f"gallery-dl failed for {url}: {e}")
        files = _collect(out_dir, marker)
        if files:
            return await done(files)

    template = os.path.join(out_dir, tmp_prefix + "%(autonumber)s.%(ext)s")
    args = ["yt-dlp", "-f", "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b", "--merge-output-format", "mp4",
            "--write-thumbnail", "--convert-thumbnails", "jpg", "--newline", "--no-cache-dir", "--no-playlist",
            "-o", template, *_cookies_args(), url]
    try:
        proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE,
                                                    stderr=asyncio.subprocess.PIPE)
        err_lines: list[str] = []

        async def read_err():
            while line := await proc.stderr.readline():
                err_lines.append(line.decode("utf-8", "replace").strip())

        err_task = asyncio.create_task(read_err())
        while True:
            line = await asyncio.wait_for(proc.stdout.readline(), timeout=300)
            if not line:
                break
            m = re.search(r"(\d+(?:\.\d+)?)%", line.decode("utf-8", "replace"))
            if m and progress:
                await progress(min(99.0, float(m.group(1))))
        await asyncio.wait_for(proc.wait(), timeout=60)
        await err_task
        files = _collect(out_dir, marker)
        if files:
            return await done(files)
        msg = next((re.sub(r"^.*?ERROR:\s*", "", l) for l in err_lines if "ERROR" in l), None)
        return False, [], msg or (err_lines[-1] if err_lines else "미디어를 찾을 수 없습니다")
    except asyncio.TimeoutError:
        return False, [], "다운로드 시간 초과"
    except Exception as e:
        return False, [], str(e)


async def _gallery_list(page_url: str, limit: int) -> list[dict]:
    try:
        code, out, _ = await _run(["gallery-dl", *_cookies_args(), "--no-download", "-j", "--range", f"1-{limit}",
                                   page_url], 180)
        return json.loads(out.decode("utf-8", "replace").strip()) if out else []
    except Exception as e:
        logger.error(f"gallery-dl list {page_url}: {e}")
        return []


async def list_user_media(username: str, limit: int = 50) -> list[dict]:
    """Recent media posts of an X account: [{url, id, title}] newest first."""
    out, seen = [], set()
    for entry in await _gallery_list(f"https://x.com/{username}/media", limit):
        if not isinstance(entry, list) or len(entry) < 3 or entry[0] not in (1, 3):
            continue
        meta = entry[2] if isinstance(entry[2], dict) else {}
        tid = str(meta.get("tweet_id") or meta.get("conversation_id") or "")
        if not tid or tid in seen:
            continue
        seen.add(tid)
        out.append({"url": f"https://x.com/{username}/status/{tid}", "id": tid,
                    "title": (meta.get("content") or "")[:100]})
    return out


async def list_user_likes(username: str, limit: int = 50) -> list[dict]:
    out, seen = [], set()
    for entry in await _gallery_list(f"https://x.com/{username}/likes", limit):
        if not isinstance(entry, list) or len(entry) < 3 or entry[0] not in (1, 3):
            continue
        meta = entry[2] if isinstance(entry[2], dict) else {}
        tid = str(meta.get("tweet_id") or meta.get("conversation_id") or "")
        if not tid or tid in seen:
            continue
        seen.add(tid)
        author = meta.get("author") or {}
        author = author.get("name", "unknown") if isinstance(author, dict) else str(author or "unknown")
        out.append({"url": f"https://x.com/{author}/status/{tid}", "id": tid,
                    "title": (meta.get("content") or "")[:100], "author": author})
    return out
