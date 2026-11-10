# PodSD

Pick podcast episodes on the web, then pull them onto a Mac with one button, ready to copy to an
MP3 player's microSD card. Built for a screen-free player (GizmoGlee-style), single user.

- **`server/`**: FastAPI + SQLite web app. Browse Apple's charts, search, subscribe, queue episodes,
  reorder the queue. HTTP Basic auth. The web is the source of truth. See
  [server/README.md](server/README.md) for running it and an nginx subpath example.
- **`Sources/`, `Package.swift`, `build.sh`**: native macOS (SwiftUI) client. It mirrors the web
  state, pushes local re-ordering back, and has a **Download Queue** button that downloads the
  queued episodes into `~/Podcasts` and marks them read on the server.

## Mac app

    ./build.sh          # builds PodSD.app next to the script (macOS 14+, Xcode command line tools)
    open PodSD.app

On first launch enter the server URL and login in Settings (the password goes in the Keychain).

Files are saved flat as `~/Podcasts/<Show> - <date> - <title>.mp3`. Whether the player handles
subfolders is unconfirmed; set `Paths.useSubfolders` in `Sources/PodSD/Models.swift` to switch to
`<Show>/<date - title>.mp3`.
