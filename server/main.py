"""PodSD server: single-user podcast subscription/queue manager. Web is the source of truth."""
import asyncio
import calendar
import html
import os
import re
import secrets
import sqlite3
import time
from contextlib import asynccontextmanager, closing
from pathlib import Path
from urllib.parse import urlparse

import feedparser
import httpx
from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from pydantic import BaseModel

DB_PATH = os.environ.get("PODSD_DB", str(Path(__file__).parent / "podsd.sqlite3"))
USER = os.environ.get("PODSD_USER", "")
PASSWORD = os.environ.get("PODSD_PASSWORD", "")
NO_AUTH = os.environ.get("PODSD_NO_AUTH") == "1"
REFRESH_SECONDS = int(os.environ.get("PODSD_REFRESH_SECONDS", "3600"))
STATIC = Path(__file__).parent / "static"

if not NO_AUTH and not (USER and PASSWORD):
    raise SystemExit("Set PODSD_USER and PODSD_PASSWORD (or PODSD_NO_AUTH=1 for local testing only).")

SCHEMA = """
CREATE TABLE IF NOT EXISTS podcasts (
  id INTEGER PRIMARY KEY,
  feed_url TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL,
  artwork_url TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  last_fetched INTEGER
);
CREATE TABLE IF NOT EXISTS episodes (
  id INTEGER PRIMARY KEY,
  podcast_id INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
  guid TEXT NOT NULL,
  title TEXT NOT NULL,
  pub_date INTEGER,
  enclosure_url TEXT NOT NULL,
  mime TEXT,
  size INTEGER,
  state TEXT NOT NULL DEFAULT 'new' CHECK (state IN ('new','queued','read')),
  queue_pos INTEGER,
  updated_at INTEGER NOT NULL,
  UNIQUE (podcast_id, guid)
);
CREATE INDEX IF NOT EXISTS episodes_state ON episodes(state, queue_pos);
CREATE INDEX IF NOT EXISTS episodes_pod ON episodes(podcast_id, pub_date DESC);
"""


def connect() -> sqlite3.Connection:
    con = sqlite3.connect(DB_PATH, timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys=ON")
    return con


def init_db() -> None:
    with closing(connect()) as con:
        con.execute("PRAGMA journal_mode=WAL")
        con.executescript(SCHEMA)
        con.commit()


# ---------- auth ----------
security = HTTPBasic(realm="PodSD")


def auth(creds: HTTPBasicCredentials = Depends(security)) -> None:
    if NO_AUTH:
        return
    ok = secrets.compare_digest(creds.username.encode(), USER.encode()) & secrets.compare_digest(
        creds.password.encode(), PASSWORD.encode()
    )
    if not ok:
        raise HTTPException(401, "Unauthorized", headers={"WWW-Authenticate": 'Basic realm="PodSD"'})


class _NoAuthSecurity(HTTPBasic):
    async def __call__(self, request):  # type: ignore[override]
        return None


if NO_AUTH:
    security = _NoAuthSecurity()


# ---------- feed fetching ----------
def _check_url(url: str) -> str:
    url = url.strip()
    if url.startswith(("feed://", "itpc://")):
        url = "https://" + url.split("://", 1)[1]
    if urlparse(url).scheme not in ("http", "https"):
        raise HTTPException(400, "Feed URL must be http(s)")
    return url


async def fetch_feed(url: str):
    async with httpx.AsyncClient(follow_redirects=True, timeout=30) as c:
        r = await c.get(url, headers={"User-Agent": "PodSD/1.0"})
        r.raise_for_status()
    return await asyncio.to_thread(feedparser.parse, r.content)


def store_feed(con: sqlite3.Connection, pid: int, parsed) -> int:
    now = int(time.time())
    art = None
    img = parsed.feed.get("image")
    if img:
        art = img.get("href") or img.get("url")
    n = 0
    for e in parsed.entries:
        encs = [x for x in e.get("enclosures", []) if x.get("href")]
        enc = next((x for x in encs if str(x.get("type", "")).startswith("audio")), encs[0] if encs else None)
        if not enc:
            continue
        pub = e.get("published_parsed")
        try:
            size = int(enc.get("length") or 0) or None
        except ValueError:
            size = None
        con.execute(
            """INSERT INTO episodes(podcast_id,guid,title,pub_date,enclosure_url,mime,size,updated_at)
               VALUES(?,?,?,?,?,?,?,?)
               ON CONFLICT(podcast_id,guid) DO UPDATE SET
                 title=excluded.title, pub_date=excluded.pub_date,
                 enclosure_url=excluded.enclosure_url, mime=excluded.mime, size=excluded.size""",
            (pid, e.get("id") or enc["href"], (e.get("title") or "Untitled").strip(),
             calendar.timegm(pub) if pub else None, enc["href"], enc.get("type"), size, now),
        )
        n += 1
    con.execute("UPDATE podcasts SET last_fetched=?, artwork_url=COALESCE(?,artwork_url) WHERE id=?", (now, art, pid))
    con.commit()
    return n


async def refresh_podcast(pid: int) -> int:
    with closing(connect()) as con:
        row = con.execute("SELECT feed_url FROM podcasts WHERE id=?", (pid,)).fetchone()
    if not row:
        raise HTTPException(404, "No such podcast")
    parsed = await fetch_feed(row["feed_url"])
    with closing(connect()) as con:
        return store_feed(con, pid, parsed)


async def refresh_loop():
    while True:
        await asyncio.sleep(REFRESH_SECONDS)
        with closing(connect()) as con:
            ids = [r["id"] for r in con.execute("SELECT id FROM podcasts")]
        for pid in ids:
            try:
                await refresh_podcast(pid)
            except Exception as ex:  # keep going; one bad feed must not stop the rest
                print(f"refresh {pid} failed: {ex}")


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    task = asyncio.create_task(refresh_loop())
    yield
    task.cancel()


app = FastAPI(title="PodSD", dependencies=[Depends(auth)], lifespan=lifespan)


# ---------- models ----------
class NewPodcast(BaseModel):
    feed_url: str


class IdList(BaseModel):
    ids: list[int]


class EpisodeState(BaseModel):
    state: str


class BulkState(BaseModel):
    ids: list[int]
    state: str


def _ep(r: sqlite3.Row) -> dict:
    return dict(r)


EP_COLS = ("e.id, e.podcast_id, p.title AS podcast_title, e.guid, e.title, e.pub_date, "
           "e.enclosure_url, e.mime, e.size, e.state, e.queue_pos")


def _podcast_rows(con):
    return [dict(r) for r in con.execute(
        """SELECT p.id, p.feed_url, p.title, p.artwork_url, p.sort_order, p.last_fetched,
                  (SELECT COUNT(*) FROM episodes WHERE podcast_id=p.id AND state='queued') AS queued,
                  (SELECT COUNT(*) FROM episodes WHERE podcast_id=p.id AND state='new') AS new_count
           FROM podcasts p ORDER BY p.sort_order, p.id""")]


def _set_state(con, ids: list[int], state: str):
    if state not in ("new", "queued", "read"):
        raise HTTPException(400, "state must be new, queued or read")
    now = int(time.time())
    for i in ids:
        row = con.execute("SELECT state FROM episodes WHERE id=?", (i,)).fetchone()
        if not row:
            continue
        if state == "queued" and row["state"] != "queued":
            pos = con.execute("SELECT COALESCE(MAX(queue_pos),0)+1 FROM episodes WHERE state='queued'").fetchone()[0]
            con.execute("UPDATE episodes SET state='queued', queue_pos=?, updated_at=? WHERE id=?", (pos, now, i))
        elif state != "queued":
            con.execute("UPDATE episodes SET state=?, queue_pos=NULL, updated_at=? WHERE id=?", (state, now, i))
    con.commit()


# ---------- API ----------
@app.get("/api/state")
def get_state():
    """Snapshot for the Mac app: ordered podcasts + the ordered download queue."""
    with closing(connect()) as con:
        queue = [_ep(r) for r in con.execute(
            f"SELECT {EP_COLS} FROM episodes e JOIN podcasts p ON p.id=e.podcast_id "
            "WHERE e.state='queued' ORDER BY e.queue_pos, e.id")]
        return {"podcasts": _podcast_rows(con), "queue": queue}


@app.get("/api/search")
async def search(q: str = Query(min_length=1)):
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.get("https://itunes.apple.com/search",
                        params={"media": "podcast", "limit": 25, "term": q})
        r.raise_for_status()
    return [{"title": x.get("collectionName", "Untitled"), "author": x.get("artistName", ""),
             "feed_url": x["feedUrl"], "artwork_url": x.get("artworkUrl100")}
            for x in r.json().get("results", []) if x.get("feedUrl")]


# ---------- Store Front: Apple charts + feed preview ----------
# Apple's top-level podcast categories (same ids the Asides app uses).
GENRES = [
    (1303, "Comedy"), (1489, "News"), (1488, "True Crime"), (1487, "History"), (1533, "Science"),
    (1318, "Technology"), (1314, "Religion & Spirituality"), (1324, "Society & Culture"),
    (1512, "Health & Fitness"), (1321, "Business"), (1304, "Education"), (1545, "Sports"),
    (1310, "Music"), (1301, "Arts"), (1483, "Fiction"), (1305, "Kids & Family"),
    (1309, "TV & Film"), (1502, "Leisure"),
]
GENRE_IDS = {g for g, _ in GENRES}
CHART_TTL = 3600
CHART_MAX = 200
_chart_cache: dict[tuple, tuple[float, list]] = {}


async def _chart(genre: int | None, size: int) -> list[dict]:
    """Apple's top-podcasts chart (overall or one category). The chart lists only ids, so a second
    lookup call fetches each show's feed URL and artwork."""
    key = (genre, size)
    hit = _chart_cache.get(key)
    if hit and time.time() - hit[0] < CHART_TTL:
        return hit[1]
    path = (f"genre={genre}/" if genre else "") + f"limit={size}/json"
    async with httpx.AsyncClient(timeout=20, follow_redirects=True) as c:
        r = await c.get(f"https://itunes.apple.com/us/rss/toppodcasts/{path}")
        r.raise_for_status()
        entries = r.json().get("feed", {}).get("entry", [])
        if isinstance(entries, dict):
            entries = [entries]
        ids = [str(e["id"]["attributes"]["im:id"]) for e in entries]
        found: dict[str, dict] = {}
        for i in range(0, len(ids), 50):
            lr = await c.get("https://itunes.apple.com/lookup",
                             params={"entity": "podcast", "id": ",".join(ids[i:i + 50])})
            lr.raise_for_status()
            for x in lr.json().get("results", []):
                if x.get("feedUrl"):
                    found[str(x.get("collectionId"))] = x
    out = []
    for rank, pid in enumerate(ids, 1):
        x = found.get(pid)
        if x:
            out.append({"rank": rank, "title": x.get("collectionName", "Untitled"),
                        "author": x.get("artistName", ""), "feed_url": x["feedUrl"],
                        "artwork_url": x.get("artworkUrl100") or x.get("artworkUrl60"),
                        "genre": x.get("primaryGenreName")})
    _chart_cache[key] = (time.time(), out)
    return out


@app.get("/api/genres")
def genres():
    return [{"id": i, "name": n} for i, n in GENRES]


@app.get("/api/charts")
async def charts(genre: int | None = None, offset: int = Query(0, ge=0), limit: int = Query(25, ge=1, le=50)):
    if genre is not None and genre not in GENRE_IDS:
        raise HTTPException(400, "Unknown genre")
    if offset >= CHART_MAX:
        return []
    size = min(offset + limit, CHART_MAX)
    try:
        items = await _chart(genre, size)
    except Exception as ex:
        raise HTTPException(502, f"Couldn't load the chart: {ex}")
    return items[offset:offset + limit]


@app.get("/api/preview")
async def preview(feed_url: str):
    """Description + latest episodes of a feed, without subscribing or storing anything."""
    url = _check_url(feed_url)
    try:
        parsed = await fetch_feed(url)
    except Exception as ex:
        raise HTTPException(400, f"Couldn't load feed: {ex}")
    f = parsed.feed
    desc = html.unescape(re.sub(r"<[^>]+>", " ", f.get("subtitle") or f.get("summary") or ""))
    eps = []
    for e in parsed.entries:
        if not any(x.get("href") for x in e.get("enclosures", [])):
            continue
        pub = e.get("published_parsed")
        eps.append({"title": (e.get("title") or "Untitled").strip(),
                    "pub_date": calendar.timegm(pub) if pub else None})
        if len(eps) >= 8:
            break
    return {"title": f.get("title", ""), "description": " ".join(desc.split())[:1200], "episodes": eps}


@app.post("/api/podcasts")
async def add_podcast(body: NewPodcast):
    url = _check_url(body.feed_url)
    with closing(connect()) as con:
        existing = con.execute("SELECT id FROM podcasts WHERE feed_url=?", (url,)).fetchone()
    if existing:
        return {"id": existing["id"], "existing": True}
    try:
        parsed = await fetch_feed(url)
    except Exception as ex:
        raise HTTPException(400, f"Couldn't load feed: {ex}")
    title = (parsed.feed.get("title") or urlparse(url).netloc).strip()
    with closing(connect()) as con:
        order = con.execute("SELECT COALESCE(MAX(sort_order),0)+1 FROM podcasts").fetchone()[0]
        cur = con.execute("INSERT INTO podcasts(feed_url,title,sort_order) VALUES(?,?,?)", (url, title, order))
        pid = cur.lastrowid
        n = store_feed(con, pid, parsed)
    return {"id": pid, "episodes": n}


@app.delete("/api/podcasts/{pid}")
def delete_podcast(pid: int):
    with closing(connect()) as con:
        con.execute("DELETE FROM podcasts WHERE id=?", (pid,))
        con.commit()
    return {"ok": True}


@app.put("/api/podcasts/order")
def order_podcasts(body: IdList):
    with closing(connect()) as con:
        for i, pid in enumerate(body.ids):
            con.execute("UPDATE podcasts SET sort_order=? WHERE id=?", (i, pid))
        con.commit()
    return {"ok": True}


@app.post("/api/podcasts/{pid}/refresh")
async def refresh(pid: int):
    try:
        return {"episodes": await refresh_podcast(pid)}
    except HTTPException:
        raise
    except Exception as ex:
        raise HTTPException(502, f"Refresh failed: {ex}")


@app.get("/api/podcasts/{pid}/episodes")
def list_episodes(pid: int, limit: int = 200, offset: int = 0, state: str | None = None):
    with closing(connect()) as con:
        sql = (f"SELECT {EP_COLS} FROM episodes e JOIN podcasts p ON p.id=e.podcast_id "
               "WHERE e.podcast_id=?")
        args: list = [pid]
        if state:
            sql += " AND e.state=?"
            args.append(state)
        sql += " ORDER BY e.pub_date DESC, e.id DESC LIMIT ? OFFSET ?"
        return [_ep(r) for r in con.execute(sql, (*args, min(limit, 1000), offset))]


@app.patch("/api/episodes/{eid}")
def patch_episode(eid: int, body: EpisodeState):
    with closing(connect()) as con:
        _set_state(con, [eid], body.state)
    return {"ok": True}


@app.post("/api/episodes/state")
def bulk_state(body: BulkState):
    with closing(connect()) as con:
        _set_state(con, body.ids, body.state)
    return {"ok": True}


@app.put("/api/queue/order")
def order_queue(body: IdList):
    with closing(connect()) as con:
        for i, eid in enumerate(body.ids):
            con.execute("UPDATE episodes SET queue_pos=? WHERE id=? AND state='queued'", (i + 1, eid))
        con.commit()
    return {"ok": True}


@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")
