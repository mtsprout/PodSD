# PodSD

Single-user podcast tool for a screen-free MP3 player (microSD card). The **web app is the source of
truth**; the Mac app mirrors it and downloads the queue to `~/Podcasts`.

## Layout
- `server/main.py`: FastAPI + SQLite (stdlib `sqlite3`), HTTP Basic auth, hourly feed refresh.
- `server/static/index.html`: the whole web UI (vanilla JS, no build step).
- `Sources/PodSD/`: SwiftUI macOS app (SwiftPM, macOS 14+). `Models.swift` (JSON types, `Paths`,
  Keychain), `Store.swift` (API client, sync, downloader), `Views.swift`, `App.swift`.
- `build.sh`: builds and ad-hoc signs `PodSD.app`. `server/README.md`: run + nginx subpath notes.

## Commands
- Mac: `./build.sh` then `open PodSD.app`
- Server (local): `cd server && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`, then
  `PODSD_USER=x PODSD_PASSWORD=y .venv/bin/uvicorn main:app --port 8000` (`PODSD_NO_AUTH=1` for local only)
- There is no test suite yet.

## Design rules
- Episode state is `new` → `queued` → `read`. The queue is ordered by `queue_pos`; shows by `sort_order`.
- Sync is pull-from-web: the Mac re-syncs before downloading and pushes local changes (reorder, state)
  back. If web and Mac disagree, the web wins.
- The **Mac downloads audio directly from the podcast feed**, never through the server. After a file
  lands it PATCHes the episode to `read`. A failed download stays queued.
- The page uses **relative URLs** (`api/...`, no leading slash) because it is served under a subpath
  behind nginx, which strips the prefix. Keep it that way; don't add absolute `/api/...` paths.
- Filenames must be FAT32-safe (`Paths.safeName`). Layout is **flat** (`<Show> - <date> - <title>.mp3`)
  because subfolder support on the player is unconfirmed; `Paths.useSubfolders` flips it.
- Apple charts use the iTunes `toppodcasts` RSS + `lookup` (feed URLs); category ids are in
  `GENRES` in `main.py`. Charts are cached in memory for an hour.
- The server's JSON is snake_case and the Mac decodes it with `.convertFromSnakeCase`, so a new API field
  needs a matching camelCase property in `Models.swift`.

## Don't
- Commit secrets, the SQLite DB, `.build/`, or `PodSD.app` (all git-ignored). Credentials come from
  `PODSD_USER`/`PODSD_PASSWORD` env vars on the server and the Keychain on the Mac.
- Put deployment hostnames or logins in this repo (it is public).
- Push, force-push, or deploy without the owner's explicit go-ahead.
