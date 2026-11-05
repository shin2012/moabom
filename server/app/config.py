"""Runtime configuration — every secret comes from the environment (.env), never from code."""
import os

APP_NAME = "모아봄"

DATA_DIR = os.environ.get("MOABOM_DATA_DIR", "/app/data")
DB_PATH = os.environ.get("MOABOM_DB", os.path.join(DATA_DIR, "moabom.db"))
LIBRARY_ROOT = os.environ.get("MOABOM_LIBRARY", "/downloads")
THUMB_DIR = os.environ.get("MOABOM_THUMB_DIR", os.path.join(DATA_DIR, "thumbs"))
COOKIES_PATH = os.environ.get("MOABOM_COOKIES", os.path.join(DATA_DIR, "cookies.txt"))

AUTH_USER = os.environ.get("MOABOM_USER", "")
AUTH_PASS = os.environ.get("MOABOM_PASS", "")
# Static key for iOS Shortcuts / scripts (X-API-Key header). Empty = disabled.
API_KEY = os.environ.get("MOABOM_API_KEY", "")

# X web client bearer used by the optional auto-like / account-status helpers. Empty = disabled.
X_WEB_BEARER = os.environ.get("MOABOM_X_BEARER", "")

# Top-level library folders that hold items by *source* rather than by category.
WATCH_DIR = os.environ.get("MOABOM_WATCH_DIR", "자동감시")
LIKES_DIR = os.environ.get("MOABOM_LIKES_DIR", "좋아요")
UNSORTED_DIR = os.environ.get("MOABOM_UNSORTED_DIR", "미분류")
LEGACY_SOURCE_DIRS = {d for d in os.environ.get("MOABOM_LEGACY_WATCH_DIRS", "").split(",") if d}

AXES = (1, 2, 3)

VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".webm"}
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".gif"}
MEDIA_EXTS = VIDEO_EXTS | IMAGE_EXTS

WEB_SESSION_DAYS = 30
LOGIN_MAX_FAILURES = 5
LOGIN_WINDOW_SECONDS = 15 * 60

# Periodic filesystem reconcile (picks up files added/removed outside the app).
RECONCILE_INTERVAL = int(os.environ.get("MOABOM_RECONCILE_INTERVAL", "600"))
