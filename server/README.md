# PodSD server

Single-user podcast subscription + download-queue manager. The web UI is the source of truth;
the Mac app mirrors it and marks episodes `read` after downloading.

## Run

    python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
    PODSD_USER=you PODSD_PASSWORD='long-random-password' \
      .venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000

Env vars: `PODSD_USER`, `PODSD_PASSWORD` (required), `PODSD_DB` (default `./podsd.sqlite3`),
`PODSD_REFRESH_SECONDS` (default 3600), `PODSD_NO_AUTH=1` (local testing only).

## Behind nginx at /podcasts/ (HTTPS only: Basic auth sends the password on every request)

The page uses relative URLs, so nginx just strips the prefix. Keep the app and database
outside the webroot (e.g. `/opt/podsd`) and run uvicorn as a systemd service bound to 127.0.0.1.

    location = /podcasts { return 301 /podcasts/; }
    location /podcasts/ {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

The Mac app's server setting is the full base URL: e.g. `https://example.com/podcasts`.
