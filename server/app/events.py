"""WebSocket fan-out for live download progress and library changes."""
import json

from fastapi import WebSocket

clients: set[WebSocket] = set()


async def broadcast(data: dict):
    msg = json.dumps(data, ensure_ascii=False)
    dead = set()
    for ws in clients:
        try:
            await ws.send_text(msg)
        except Exception:
            dead.add(ws)
    clients.difference_update(dead)
