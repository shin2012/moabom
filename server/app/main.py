import asyncio
import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse

from app import auth, config, db, dlqueue, events, library, watcher
from app.routes import auth_routes, category_routes, download_routes, library_routes, misc_routes

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(levelname)s: %(message)s")
logging.getLogger("httpx").setLevel(logging.WARNING)
logger = logging.getLogger("moabom")

STATIC = os.path.join(os.path.dirname(__file__), "static")


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.init_db()
    if not config.AUTH_USER or not config.AUTH_PASS:
        logger.warning("MOABOM_USER / MOABOM_PASS not set — login is disabled")
    tasks = []
    if os.environ.get("MOABOM_BACKGROUND", "1") == "1":
        tasks = [asyncio.create_task(dlqueue.worker()), asyncio.create_task(dlqueue.resume()),
                 asyncio.create_task(library.background_loop()),
                 asyncio.create_task(watcher.loop(dlqueue.enqueue))]
    logger.info(f"{config.APP_NAME} started")
    yield
    for t in tasks:
        t.cancel()


app = FastAPI(title=config.APP_NAME, lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
for r in (auth_routes, library_routes, category_routes, download_routes, misc_routes):
    app.include_router(r.router)


@app.websocket("/ws")
async def ws(websocket: WebSocket):
    if not await auth.ws_authorized(websocket):
        await websocket.close(code=4401)
        return
    await websocket.accept()
    events.clients.add(websocket)
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        events.clients.discard(websocket)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/")
async def index():
    return FileResponse(os.path.join(STATIC, "index.html"), headers={"Cache-Control": "no-cache"})


@app.get("/{name}.{ext}")
async def static_file(name: str, ext: str):
    allowed = {"js", "css", "png", "svg", "webmanifest", "ico"}
    path = os.path.normpath(os.path.join(STATIC, f"{name}.{ext}"))
    if ext not in allowed or not path.startswith(STATIC) or not os.path.isfile(path):
        return FileResponse(os.path.join(STATIC, "index.html"), status_code=404)
    return FileResponse(path, headers={"Cache-Control": "no-cache"})
