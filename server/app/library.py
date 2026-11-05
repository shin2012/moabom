"""Media library: the DB index of files under LIBRARY_ROOT and every operation that moves/deletes them.

Folder layout on disk (the NAS share stays browsable without the app):
    <cat1>/<cat2>/<cat3>/<file>      classified items (trailing empty axes dropped, gaps -> UNSORTED_DIR)
    <WATCH_DIR>/@<account>/<file>     unclassified items from watched accounts
    <LIKES_DIR>/<file>                unclassified items from the likes watcher
    <UNSORTED_DIR>/<file>             unclassified manual items

Category names live only in the DB; a category's folder name is derived from its name.
"""
import asyncio
import logging
import os
import re
import shutil
from datetime import datetime

from app import config
from app import db

logger = logging.getLogger("moabom.library")

# Serialises every operation that touches files so moves/scans never interleave.
lock = asyncio.Lock()

AXIS_KEYS = ("c1", "c2", "c3")
SKIP_DIRS = {"@eaDir", "@Recycle", "@tmp", "@sharebin", "@__thumb"}


# ─────────────────────────── helpers ───────────────────────────
def safe_folder(name: str) -> str:
    name = (name or "").strip()
    name = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", "_", name)
    name = name.strip(". ")
    return name[:80]


def media_kind(ext: str) -> str | None:
    ext = ext.lower()
    if ext in config.VIDEO_EXTS:
        return "video"
    if ext in config.IMAGE_EXTS:
        return "image"
    return None


def _abs(rel: str) -> str:
    return os.path.normpath(os.path.join(config.LIBRARY_ROOT, rel))


def _is_inside_root(path: str) -> bool:
    root = os.path.normpath(config.LIBRARY_ROOT)
    return path == root or path.startswith(root + os.sep)


_OWNER_RES = (
    re.compile(r"^(?P<h>.+)_\d{14}_\d{3}(?:_\d+)?$"),
    re.compile(r"^(?P<h>.+?)_\d{8,20}_\d+$"),
)


def parse_owner(base: str) -> str | None:
    for rx in _OWNER_RES:
        m = rx.match(base)
        if m:
            return m.group("h").lstrip("@")
    return None


def source_dirs() -> dict[str, str]:
    d = {config.WATCH_DIR: "watch", config.LIKES_DIR: "likes"}
    for legacy in config.LEGACY_SOURCE_DIRS:
        d[legacy] = "watch"
    return d


def parse_location(rel_dir: str) -> dict:
    """Interpret a directory (relative to root) as {source, watched_by, folders:[f1,f2,f3]}."""
    parts = [p for p in rel_dir.split("/") if p and p != "."]
    out = {"source": "manual", "watched_by": None, "folders": [None, None, None]}
    if not parts:
        return out
    src = source_dirs().get(parts[0])
    if src:
        out["source"] = src
        if src == "watch" and len(parts) > 1:
            out["watched_by"] = parts[1].lstrip("@")
        return out
    for i, p in enumerate(parts[:3]):
        out["folders"][i] = None if p == config.UNSORTED_DIR else p
    return out


def target_dir(cats: dict, catrows: dict, source: str, watched_by: str | None) -> str:
    ids = [cats.get(k) for k in AXIS_KEYS]
    if any(ids):
        last = max(i for i, v in enumerate(ids) if v)
        segs = []
        for i in range(last + 1):
            cid = ids[i]
            segs.append(catrows[cid]["folder"] if cid and cid in catrows else config.UNSORTED_DIR)
        return "/".join(segs)
    if source == "watch" and watched_by:
        return f"{config.WATCH_DIR}/@{watched_by}"
    if source == "likes":
        return config.LIKES_DIR
    return config.UNSORTED_DIR


def _siblings(abs_main: str) -> list[str]:
    """Main file + every same-basename media file next to it (thumbnail/video pair)."""
    base = os.path.splitext(abs_main)[0]
    out = [abs_main]
    for ext in config.MEDIA_EXTS | {e.upper() for e in config.MEDIA_EXTS}:
        p = base + ext
        if p != abs_main and os.path.exists(p) and p not in out:
            out.append(p)
    return out


def _unique_dest(dest_dir: str, fname: str, taken: set[str]) -> str:
    base, ext = os.path.splitext(fname)
    cand = os.path.join(dest_dir, fname)
    n = 2
    while os.path.exists(cand) or cand in taken:
        cand = os.path.join(dest_dir, f"{base}_{n}{ext}")
        n += 1
    return cand


def _move_group(abs_main: str, dest_dir_rel: str) -> tuple[str, dict[str, str]]:
    """Move a media file and its same-base siblings into dest_dir. Returns (new_main_abs, {old: new})."""
    dest_dir = _abs(dest_dir_rel)
    if not _is_inside_root(dest_dir):
        raise ValueError("잘못된 대상 폴더")
    if os.path.dirname(abs_main) == dest_dir:
        return abs_main, {}
    os.makedirs(dest_dir, exist_ok=True)
    group = _siblings(abs_main)
    # Keep the pair's shared basename: pick a basename free for every member.
    base = os.path.splitext(os.path.basename(abs_main))[0]
    new_base = base
    n = 2
    while any(os.path.exists(os.path.join(dest_dir, new_base + os.path.splitext(p)[1])) for p in group):
        new_base = f"{base}_{n}"
        n += 1
    moved: dict[str, str] = {}
    try:
        for p in group:
            dst = os.path.join(dest_dir, new_base + os.path.splitext(p)[1])
            try:
                os.replace(p, dst)
            except OSError:
                shutil.move(p, dst)
            moved[p] = dst
    except Exception:
        for src, dst in moved.items():  # roll back
            try:
                os.replace(dst, src)
            except OSError:
                pass
        raise
    _prune_empty_dirs(os.path.dirname(abs_main))
    return moved[abs_main], moved


def _prune_empty_dirs(d: str):
    root = os.path.normpath(config.LIBRARY_ROOT)
    d = os.path.normpath(d)
    while d != root and _is_inside_root(d) and os.path.isdir(d):
        try:
            entries = [e for e in os.listdir(d) if e not in ("@eaDir", ".DS_Store")]
            if entries:
                break
            eadir = os.path.join(d, "@eaDir")
            if os.path.isdir(eadir):
                shutil.rmtree(eadir, ignore_errors=True)
            os.rmdir(d)
        except OSError:
            break
        d = os.path.dirname(d)


def _rel(abs_path: str) -> str:
    return os.path.relpath(abs_path, config.LIBRARY_ROOT).replace(os.sep, "/")


# ─────────────────────────── categories ───────────────────────────
async def load_categories(conn, include_deleted: bool = False) -> dict[int, dict]:
    q = "SELECT * FROM categories" + ("" if include_deleted else " WHERE deleted = 0")
    cur = await conn.execute(q)
    return {r["id"]: dict(r) for r in await cur.fetchall()}


async def _folder_index(conn) -> dict[tuple[int, str], int]:
    cats = await load_categories(conn)
    return {(c["axis"], c["folder"]): cid for cid, c in cats.items()}


async def _ensure_category(conn, axis: int, folder: str, index: dict) -> int:
    key = (axis, folder)
    if key in index:
        return index[key]
    cur = await conn.execute("SELECT COALESCE(MAX(sort), 0) + 1 AS s FROM categories WHERE axis = ?", (axis,))
    sort = (await cur.fetchone())["s"]
    rev = await db.next_revs(conn)
    cur = await conn.execute("INSERT INTO categories (axis, name, folder, sort, rev) VALUES (?, ?, ?, ?, ?)",
                             (axis, folder, folder, sort, rev))
    index[key] = cur.lastrowid
    return cur.lastrowid


async def axis_names() -> list[str]:
    names = []
    for a in config.AXES:
        names.append(await db.get_setting(f"axis{a}_name", f"분류 {a}"))
    return names


# ─────────────────────────── scanning ───────────────────────────
def _walk_library() -> list[dict]:
    """Group files into media items. Runs in a worker thread."""
    root = config.LIBRARY_ROOT
    items = []
    if not os.path.isdir(root):
        return items
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith((".", "#")) and d not in SKIP_DIRS]
        groups: dict[str, list[str]] = {}
        for f in filenames:
            if f.startswith(".") or f.endswith((".part", ".tmp", ".ytdl")):
                continue
            base, ext = os.path.splitext(f)
            if not media_kind(ext):
                continue
            groups.setdefault(base, []).append(f)
        rel_dir = os.path.relpath(dirpath, root).replace(os.sep, "/")
        rel_dir = "" if rel_dir == "." else rel_dir
        for base, files in groups.items():
            videos = sorted(f for f in files if media_kind(os.path.splitext(f)[1]) == "video")
            images = sorted(f for f in files if media_kind(os.path.splitext(f)[1]) == "image")
            if videos:
                main = videos[0]
                thumb = next((i for i in images if i.lower().endswith((".jpg", ".jpeg"))), images[0] if images else None)
                entries = [(main, "video", thumb)]
            else:
                entries = [(images[0], "image", None)]
            for fname, kind, thumb in entries:
                full = os.path.join(dirpath, fname)
                try:
                    st = os.stat(full)
                except OSError:
                    continue
                items.append({
                    "path": f"{rel_dir}/{fname}" if rel_dir else fname,
                    "dir": rel_dir,
                    "name": fname,
                    "thumb": (f"{rel_dir}/{thumb}" if rel_dir else thumb) if thumb else None,
                    "kind": kind,
                    "size": st.st_size,
                    "mtime": st.st_mtime,
                })
    return items


async def _download_index(conn) -> dict[str, dict]:
    """basename -> download metadata, used to enrich newly indexed files."""
    cur = await conn.execute("SELECT url, username, display_name, title, uploaded_at, completed_at, watched_by, filepath "
                             "FROM downloads WHERE status = 'completed' AND filepath IS NOT NULL")
    out = {}
    for r in await cur.fetchall():
        for p in (r["filepath"] or "").split(", "):
            if p:
                out[os.path.basename(p.strip())] = dict(r)
    return out


async def reconcile() -> dict:
    """Bring the media table in line with the filesystem. Never moves files."""
    async with lock:
        found = await asyncio.to_thread(_walk_library)
        async with db.connect() as conn:
            cur = await conn.execute("SELECT * FROM media WHERE deleted = 0")
            live = {r["path"]: dict(r) for r in await cur.fetchall()}
            index = await _folder_index(conn)
            dl_index = None
            stats = {"added": 0, "moved": 0, "removed": 0, "updated": 0}
            found_paths = {f["path"] for f in found}
            missing = {p: r for p, r in live.items() if p not in found_paths}
            missing_by_key = {}
            for p, r in missing.items():
                missing_by_key.setdefault((os.path.basename(p), r["size"]), r)

            for f in found:
                loc = parse_location(f["dir"])
                cats = {}
                for i, folder in enumerate(loc["folders"]):
                    cats[AXIS_KEYS[i]] = await _ensure_category(conn, i + 1, folder, index) if folder else None
                row = live.get(f["path"])
                if row:
                    changes = {}
                    if row["thumb"] != f["thumb"]:
                        changes["thumb"] = f["thumb"]
                    if row["size"] != f["size"]:
                        changes.update(size=f["size"], probed=0)
                    if loc["source"] == "manual":
                        for k in AXIS_KEYS:
                            if row[k] != cats[k]:
                                changes[k] = cats[k]
                    if changes:
                        changes["rev"] = await db.next_revs(conn)
                        sets = ", ".join(f"{k} = ?" for k in changes)
                        await conn.execute(f"UPDATE media SET {sets} WHERE id = ?", [*changes.values(), row["id"]])
                        stats["updated"] += 1
                    continue
                moved_from = missing_by_key.pop((f["name"], f["size"]), None)
                if moved_from:
                    missing.pop(moved_from["path"], None)
                    upd = {"path": f["path"], "thumb": f["thumb"], "rev": await db.next_revs(conn)}
                    if loc["source"] != "manual":
                        upd.update(source=loc["source"], watched_by=loc["watched_by"] or moved_from["watched_by"])
                    upd.update(cats)
                    sets = ", ".join(f"{k} = ?" for k in upd)
                    await conn.execute(f"UPDATE media SET {sets} WHERE id = ?", [*upd.values(), moved_from["id"]])
                    stats["moved"] += 1
                    continue
                if dl_index is None:
                    dl_index = await _download_index(conn)
                meta = dl_index.get(f["name"], {})
                base = os.path.splitext(f["name"])[0]
                added_at = meta.get("completed_at") or datetime.fromtimestamp(f["mtime"]).isoformat(timespec="seconds")
                await conn.execute(
                    "INSERT INTO media (path, thumb, kind, size, mtime, c1, c2, c3, source, owner, watched_by, title, "
                    "source_url, uploaded_at, added_at, rev) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (f["path"], f["thumb"], f["kind"], f["size"], f["mtime"], cats["c1"], cats["c2"], cats["c3"],
                     loc["source"], meta.get("username") or parse_owner(base) or loc["watched_by"],
                     loc["watched_by"] or meta.get("watched_by"), (meta.get("title") or "")[:300] or None,
                     meta.get("url"), meta.get("uploaded_at"), added_at, await db.next_revs(conn)),
                )
                stats["added"] += 1
            for p, r in missing.items():
                await conn.execute("UPDATE media SET deleted = 1, rev = ? WHERE id = ?", (await db.next_revs(conn), r["id"]))
                stats["removed"] += 1
            await conn.commit()
        if any(stats.values()):
            logger.info(f"reconcile: {stats}")
        return stats


async def index_files(abs_paths: list[str], meta: dict) -> list[int]:
    """Register freshly downloaded files immediately (no full rescan)."""
    async with lock:
        groups: dict[tuple[str, str], list[str]] = {}
        for p in abs_paths:
            if not os.path.exists(p) or not media_kind(os.path.splitext(p)[1]):
                continue
            groups.setdefault((os.path.dirname(p), os.path.splitext(os.path.basename(p))[0]), []).append(p)
        ids = []
        async with db.connect() as conn:
            for (d, base), files in groups.items():
                vids = sorted(f for f in files if media_kind(os.path.splitext(f)[1]) == "video")
                imgs = sorted(f for f in files if media_kind(os.path.splitext(f)[1]) == "image")
                if vids:
                    main, kind = vids[0], "video"
                    thumb = next((i for i in imgs if i.lower().endswith((".jpg", ".jpeg"))), imgs[0] if imgs else None)
                else:
                    main, kind, thumb = imgs[0], "image", None
                st = os.stat(main)
                rel = _rel(main)
                cur = await conn.execute("SELECT id FROM media WHERE path = ? AND deleted = 0", (rel,))
                if await cur.fetchone():
                    continue
                cur = await conn.execute(
                    "INSERT INTO media (path, thumb, kind, size, mtime, c1, c2, c3, source, owner, watched_by, title, "
                    "source_url, uploaded_at, added_at, rev) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (rel, _rel(thumb) if thumb else None, kind, st.st_size, st.st_mtime,
                     meta.get("c1"), meta.get("c2"), meta.get("c3"), meta.get("source") or "manual",
                     meta.get("owner") or parse_owner(base), meta.get("watched_by"),
                     (meta.get("title") or "")[:300] or None, meta.get("url"), meta.get("uploaded_at"),
                     datetime.now().isoformat(timespec="seconds"), await db.next_revs(conn)),
                )
                ids.append(cur.lastrowid)
            await conn.commit()
        return ids


# ─────────────────────────── queries ───────────────────────────
MEDIA_FIELDS = ("id", "path", "thumb", "kind", "size", "width", "height", "duration", "c1", "c2", "c3", "source",
                "owner", "watched_by", "title", "source_url", "uploaded_at", "added_at", "favorite", "rev", "deleted")


def media_out(r: dict) -> dict:
    return {k: r.get(k) for k in MEDIA_FIELDS}


async def get_media(ids: list[int]) -> list[dict]:
    if not ids:
        return []
    async with db.connect() as conn:
        q = f"SELECT * FROM media WHERE id IN ({','.join('?' * len(ids))})"
        cur = await conn.execute(q, ids)
        return [dict(r) for r in await cur.fetchall()]


async def changes(since: int, limit: int = 2000) -> dict:
    async with db.connect() as conn:
        cur = await conn.execute("SELECT * FROM media WHERE rev > ? ORDER BY rev LIMIT ?", (since, limit))
        rows = [dict(r) for r in await cur.fetchall()]
        cur = await conn.execute("SELECT * FROM categories WHERE rev > ? ORDER BY rev", (since,))
        cats = [dict(r) for r in await cur.fetchall()]
        head = await db.current_rev(conn)
    more = len(rows) == limit
    cursor = rows[-1]["rev"] if more else head
    return {
        "rev": cursor,
        "has_more": more,
        "media": [media_out(r) for r in rows],
        "categories": [{k: c[k] for k in ("id", "axis", "name", "sort", "deleted", "rev")} for c in cats],
        "axes": await axis_names(),
    }


# ─────────────────────────── mutations ───────────────────────────
async def classify(ids: list[int], updates: dict) -> list[dict]:
    """updates: {"c1": id|None, ...} — keys present are applied, absent keys are kept.
    Moves files on disk accordingly. Returns [{id, before:{c1,c2,c3}}] for undo."""
    updates = {k: v for k, v in updates.items() if k in AXIS_KEYS}
    undo = []
    async with lock:
        async with db.connect() as conn:
            catrows = await load_categories(conn)
            for k, v in updates.items():
                if v is not None and (v not in catrows or catrows[v]["axis"] != int(k[1])):
                    raise ValueError(f"잘못된 분류 ({k}={v})")
            for mid in ids:
                cur = await conn.execute("SELECT * FROM media WHERE id = ? AND deleted = 0", (mid,))
                row = await cur.fetchone()
                if not row:
                    continue
                row = dict(row)
                new = {k: (updates[k] if k in updates else row[k]) for k in AXIS_KEYS}
                before = {k: row[k] for k in AXIS_KEYS}
                await _relocate(conn, row, new, catrows)
                undo.append({"id": mid, "before": before})
            await conn.commit()
    return undo


async def restore_classification(items: list[dict]):
    """Undo helper: items = [{id, before:{c1,c2,c3}}]."""
    async with lock:
        async with db.connect() as conn:
            catrows = await load_categories(conn)
            for it in items:
                cur = await conn.execute("SELECT * FROM media WHERE id = ? AND deleted = 0", (it["id"],))
                row = await cur.fetchone()
                if not row:
                    continue
                before = {k: (it["before"].get(k) if it["before"].get(k) in catrows else None) for k in AXIS_KEYS}
                await _relocate(conn, dict(row), before, catrows)
            await conn.commit()


async def _relocate(conn, row: dict, new_cats: dict, catrows: dict):
    """Set categories on a media row and move its files to the matching folder. Caller holds lock & commits."""
    dest = target_dir(new_cats, catrows, row["source"], row["watched_by"])
    abs_main = _abs(row["path"])
    new_path, new_thumb = row["path"], row["thumb"]
    if os.path.exists(abs_main):
        new_abs, moved = await asyncio.to_thread(_move_group, abs_main, dest)
        new_path = _rel(new_abs)
        if row["thumb"]:
            t_abs = _abs(row["thumb"])
            new_thumb = _rel(moved[t_abs]) if t_abs in moved else row["thumb"]
    rev = await db.next_revs(conn)
    await conn.execute("UPDATE media SET path = ?, thumb = ?, c1 = ?, c2 = ?, c3 = ?, rev = ? WHERE id = ?",
                       (new_path, new_thumb, new_cats["c1"], new_cats["c2"], new_cats["c3"], rev, row["id"]))


async def delete_media(ids: list[int]) -> int:
    count = 0
    async with lock:
        async with db.connect() as conn:
            for mid in ids:
                cur = await conn.execute("SELECT * FROM media WHERE id = ? AND deleted = 0", (mid,))
                row = await cur.fetchone()
                if not row:
                    continue
                abs_main = _abs(row["path"])
                if _is_inside_root(abs_main) and os.path.exists(abs_main):
                    for p in _siblings(abs_main):
                        try:
                            os.remove(p)
                        except OSError:
                            pass
                    _prune_empty_dirs(os.path.dirname(abs_main))
                await conn.execute("UPDATE media SET deleted = 1, rev = ? WHERE id = ?", (await db.next_revs(conn), mid))
                _drop_thumb_cache(mid)
                count += 1
            await conn.commit()
    return count


async def set_favorite(ids: list[int], value: bool):
    async with db.connect() as conn:
        for mid in ids:
            await conn.execute("UPDATE media SET favorite = ?, rev = ? WHERE id = ? AND deleted = 0",
                               (1 if value else 0, await db.next_revs(conn), mid))
        await conn.commit()


# ─── category management (all of these move files on disk) ───
async def create_category(axis: int, name: str) -> dict:
    if axis not in config.AXES:
        raise ValueError("잘못된 분류 축")
    folder = safe_folder(name)
    if not folder or folder == config.UNSORTED_DIR or folder in source_dirs():
        raise ValueError("사용할 수 없는 이름입니다")
    async with lock:
        async with db.connect() as conn:
            cur = await conn.execute("SELECT id FROM categories WHERE axis = ? AND folder = ? AND deleted = 0", (axis, folder))
            if await cur.fetchone():
                raise ValueError("같은 이름의 분류가 이미 있습니다")
            cur = await conn.execute("SELECT COALESCE(MAX(sort), 0) + 1 AS s FROM categories WHERE axis = ?", (axis,))
            sort = (await cur.fetchone())["s"]
            cur = await conn.execute("INSERT INTO categories (axis, name, folder, sort, rev) VALUES (?, ?, ?, ?, ?)",
                                     (axis, name.strip(), folder, sort, await db.next_revs(conn)))
            await conn.commit()
            return {"id": cur.lastrowid, "axis": axis, "name": name.strip(), "sort": sort}


async def _media_with_category(conn, cid: int) -> list[dict]:
    cur = await conn.execute("SELECT * FROM media WHERE deleted = 0 AND (c1 = ? OR c2 = ? OR c3 = ?)", (cid, cid, cid))
    return [dict(r) for r in await cur.fetchall()]


async def rename_category(cid: int, name: str) -> int:
    folder = safe_folder(name)
    if not folder or folder == config.UNSORTED_DIR or folder in source_dirs():
        raise ValueError("사용할 수 없는 이름입니다")
    async with lock:
        async with db.connect() as conn:
            catrows = await load_categories(conn)
            if cid not in catrows:
                raise ValueError("분류를 찾을 수 없습니다")
            axis = catrows[cid]["axis"]
            clash = [c for c in catrows.values() if c["axis"] == axis and c["folder"] == folder and c["id"] != cid]
            if clash:
                raise ValueError("같은 이름의 분류가 이미 있습니다. 합치기를 사용하세요")
            await conn.execute("UPDATE categories SET name = ?, folder = ?, rev = ? WHERE id = ?",
                               (name.strip(), folder, await db.next_revs(conn), cid))
            catrows[cid].update(name=name.strip(), folder=folder)
            rows = await _media_with_category(conn, cid)
            for row in rows:
                await _relocate(conn, row, {k: row[k] for k in AXIS_KEYS}, catrows)
            await conn.commit()
            return len(rows)


async def merge_category(src: int, dst: int) -> int:
    async with lock:
        async with db.connect() as conn:
            catrows = await load_categories(conn)
            if src not in catrows or dst not in catrows or src == dst:
                raise ValueError("분류를 찾을 수 없습니다")
            if catrows[src]["axis"] != catrows[dst]["axis"]:
                raise ValueError("같은 단계의 분류끼리만 합칠 수 있습니다")
            key = f"c{catrows[src]['axis']}"
            rows = await _media_with_category(conn, src)
            for row in rows:
                new = {k: row[k] for k in AXIS_KEYS}
                new[key] = dst
                await _relocate(conn, row, new, catrows)
            await conn.execute("UPDATE categories SET deleted = 1, rev = ? WHERE id = ?", (await db.next_revs(conn), src))
            await conn.execute("UPDATE downloads SET " + key + " = ? WHERE " + key + " = ?", (dst, src))
            await conn.commit()
            return len(rows)


async def delete_category(cid: int) -> int:
    """Delete a category; its items lose that classification (files move accordingly)."""
    async with lock:
        async with db.connect() as conn:
            catrows = await load_categories(conn)
            if cid not in catrows:
                raise ValueError("분류를 찾을 수 없습니다")
            key = f"c{catrows[cid]['axis']}"
            rows = await _media_with_category(conn, cid)
            for row in rows:
                new = {k: row[k] for k in AXIS_KEYS}
                new[key] = None
                await _relocate(conn, row, new, catrows)
            await conn.execute("UPDATE categories SET deleted = 1, rev = ? WHERE id = ?", (await db.next_revs(conn), cid))
            await conn.execute("UPDATE downloads SET " + key + " = NULL WHERE " + key + " = ?", (cid,))
            await conn.commit()
            return len(rows)


async def reorder_categories(axis: int, ids: list[int]):
    async with db.connect() as conn:
        for i, cid in enumerate(ids):
            await conn.execute("UPDATE categories SET sort = ?, rev = ? WHERE id = ? AND axis = ?",
                               (i + 1, await db.next_revs(conn), cid, axis))
        await conn.commit()


async def set_axis_names(names: list[str]):
    for i, n in enumerate(names[:3]):
        n = (n or "").strip()[:20]
        if n:
            await db.set_setting(f"axis{i + 1}_name", n)
    # Bump a revision so clients re-read axis names on next sync.
    async with db.connect() as conn:
        await db.next_revs(conn)
        await conn.commit()


# ─────────────────────────── thumbnails & probing ───────────────────────────
THUMB_WIDTHS = (240, 480, 960)


def _thumb_cache_path(mid: int, w: int) -> str:
    return os.path.join(config.THUMB_DIR, str(mid % 100), f"{mid}-{w}.jpg")


def _drop_thumb_cache(mid: int):
    for w in THUMB_WIDTHS:
        try:
            os.remove(_thumb_cache_path(mid, w))
        except OSError:
            pass


async def thumbnail(row: dict, w: int) -> str | None:
    w = min(THUMB_WIDTHS, key=lambda x: abs(x - w))
    out = _thumb_cache_path(row["id"], w)
    if os.path.exists(out):
        return out
    src = _abs(row["thumb"]) if row["thumb"] else _abs(row["path"])
    if not os.path.exists(src):
        return None
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp.jpg"
    attempts = [["-ss", "1"], []] if row["kind"] == "video" and not row["thumb"] else [[]]
    try:
        for seek in attempts:
            args = ["ffmpeg", "-y", "-loglevel", "error", *seek, "-i", src, "-frames:v", "1",
                    "-vf", f"scale='min({w},iw)':-2", "-q:v", "4", tmp]
            proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.DEVNULL,
                                                        stderr=asyncio.subprocess.DEVNULL)
            await asyncio.wait_for(proc.wait(), timeout=20)
            if proc.returncode == 0 and os.path.exists(tmp) and os.path.getsize(tmp) > 0:
                os.replace(tmp, out)
                return out
    except Exception as e:
        logger.debug(f"thumb {row['id']} failed: {e}")
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return None


async def _probe(path: str) -> dict | None:
    try:
        proc = await asyncio.create_subprocess_exec(
            "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration",
            "-of", "default=nw=1", path, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=20)
        vals = {}
        for line in out.decode(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                vals[k] = v
        w, h = int(vals.get("width") or 0), int(vals.get("height") or 0)
        dur = vals.get("duration")
        return {"width": w or None, "height": h or None,
                "duration": float(dur) if dur and dur not in ("N/A",) else None}
    except Exception:
        return None


async def probe_pending(batch: int = 50) -> int:
    async with db.connect() as conn:
        cur = await conn.execute("SELECT id, path, kind FROM media WHERE deleted = 0 AND probed = 0 LIMIT ?", (batch,))
        rows = [dict(r) for r in await cur.fetchall()]
    done = 0
    for r in rows:
        info = await _probe(_abs(r["path"])) or {}
        async with db.connect() as conn:
            await conn.execute("UPDATE media SET width = ?, height = ?, duration = ?, probed = 1, rev = ? WHERE id = ?",
                               (info.get("width"), info.get("height"),
                                info.get("duration") if r["kind"] == "video" else None,
                                await db.next_revs(conn), r["id"]))
            await conn.commit()
        done += 1
        await asyncio.sleep(0.05)
    return done


async def background_loop():
    """Initial index + periodic reconcile + metadata probing."""
    await asyncio.sleep(2)
    last = 0.0
    loop = asyncio.get_running_loop()
    while True:
        try:
            if loop.time() - last >= config.RECONCILE_INTERVAL or last == 0.0:
                await reconcile()
                last = loop.time()
            n = await probe_pending()
            await asyncio.sleep(1 if n else 30)
        except Exception as e:
            logger.error(f"library loop error: {e}")
            await asyncio.sleep(30)
