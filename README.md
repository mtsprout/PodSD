# PodSD

Pick podcast episodes on the web, then pull them onto a Mac with one button, ready to copy to an
MP3 player's microSD card. Built for a screen-free player (GizmoGlee-style), single user.

- **`server/`**: FastAPI + SQLite web app. Browse Apple's charts, search, subscribe, queue episodes,
  reorder the queue. HTTP Basic auth. The web is the source of truth. See
  [server/README.md](server/README.md) for running it and an nginx subpath example.
- **`Sources/`, `Package.swift`, `build.sh`**: small native macOS (SwiftUI) client: **Setup**, **Sync**
  and **Download Queue**. It pulls the queue you built on the web, downloads those episodes into a
  folder you pick (on this Mac, or straight onto the player's card), and marks them read on the server.

## Mac app

    ./build.sh          # builds PodSD.app next to the script (macOS 14+, Xcode command line tools)
    open PodSD.app

On first launch enter the server URL and login in Settings (the password goes in the Keychain).

**Download Queue…** opens a folder dialog (defaulting to the player's card if one is plugged in) and warns
if the queue won't fit in the free space. By default files are saved flat in that folder as
`<Show> - <date> - <title>.mp3`. Whether the player handles
subfolders is unconfirmed; turn on **Use subfolders** in Setup to save as
`<Show>/<date - title>.mp3` instead.
