import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case queue
    case show(Int)
}

func reveal(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var selection: SidebarItem? = .queue
    @State private var showAdd = false
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Download queue (\(store.queue.count))", systemImage: "tray.full").tag(SidebarItem.queue)
                Section("Shows") {
                    ForEach(store.podcasts) { p in
                        HStack {
                            Artwork(url: p.artwork, size: 26)
                            Text(p.title).lineLimit(1)
                            Spacer()
                            if p.queued > 0 { Text("\(p.queued)").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(SidebarItem.show(p.id))
                        .contextMenu {
                            Button("Show in Finder") { reveal(Paths.useSubfolders ? Paths.folder(forShow: p.title) : Paths.downloadsRoot) }
                            Button("Unsubscribe", role: .destructive) { Task { await store.unsubscribe(p) } }
                        }
                    }
                    .onMove { from, to in Task { await store.movePodcasts(from: from, to: to) } }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250)
            .toolbar {
                ToolbarItemGroup {
                    Button { Task { await store.sync() } } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(store.syncing)
                    Button { showAdd = true } label: { Label("Add Podcast", systemImage: "plus") }
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
        } detail: {
            switch selection {
            case .show(let id):
                if let p = store.podcasts.first(where: { $0.id == id }) { ShowView(podcast: p).id(id) }
                else { Text("Show not found").foregroundStyle(.secondary) }
            default:
                QueueView()
            }
        }
        .sheet(isPresented: $showAdd) { AddPodcastView().environmentObject(store) }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .alert("Error", isPresented: .constant(store.errorMessage != nil)) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .frame(minWidth: 860, minHeight: 540)
        .task {
            if store.isConfigured { await store.sync() } else { showSettings = true }
        }
    }
}

struct Artwork: View {
    var url: URL?
    var size: CGFloat
    var body: some View {
        AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size / 6))
    }
}

// MARK: Queue

struct QueueView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        List {
            ForEach(store.queue) { e in
                QueueRow(episode: e)
            }
            .onMove { from, to in Task { await store.moveQueue(from: from, to: to) } }
        }
        .overlay {
            if store.queue.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "tray",
                                       description: Text("Pick episodes on the web (or in a show here) to queue them."))
            }
        }
        .navigationTitle("Download queue")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(store.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { reveal(Paths.downloadsRoot) } label: { Label("Open Folder", systemImage: "folder") }
                Button { Task { await store.downloadQueue() } } label: {
                    Label("Download Queue", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.downloading || store.queue.isEmpty)
            }
            .padding(10).background(.bar)
        }
    }
}

struct QueueRow: View {
    @EnvironmentObject var store: Store
    let episode: Episode

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).lineLimit(2)
                EpisodeSubtitle(episode: episode, showPodcast: true)
            }
            Spacer()
            if let p = store.progress[episode.id] {
                ProgressView(value: p).frame(width: 90)
            } else if store.isOnDisk(episode) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Already on disk")
            }
            Button { Task { await store.setState([episode.id], "new") } } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).help("Remove from queue")
        }
        .padding(.vertical, 2)
    }
}

struct EpisodeSubtitle: View {
    let episode: Episode
    var showPodcast = false
    var body: some View {
        HStack(spacing: 8) {
            if showPodcast { Text(episode.podcastTitle) }
            if let d = episode.date { Text(d.formatted(date: .abbreviated, time: .omitted)) }
            if let s = episode.size, s > 0 { Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
            if !episode.isMP3 {
                Label("\(episode.fileExtension.uppercased()) – may not play", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: Show

struct ShowView: View {
    @EnvironmentObject var store: Store
    let podcast: Podcast
    @State private var selected = Set<Int>()

    private var episodes: [Episode] { store.showEpisodes[podcast.id] ?? [] }

    var body: some View {
        List(episodes, selection: $selected) { e in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).lineLimit(2)
                    EpisodeSubtitle(episode: e)
                }
                Spacer()
                Text(e.state).font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .overlay(Capsule().stroke(e.state == "queued" ? Color.accentColor : e.state == "read" ? .green : .secondary.opacity(0.5)))
                    .foregroundStyle(e.state == "queued" ? Color.accentColor : e.state == "read" ? .green : .secondary)
            }
        }
        .navigationTitle(podcast.title)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await store.setState(Array(selected), "queued", in: podcast); selected = [] } }
                    label: { Label("Queue Selected", systemImage: "plus.circle") }.disabled(selected.isEmpty)
                Button { Task { await store.setState(Array(selected), "read", in: podcast); selected = [] } }
                    label: { Label("Mark Read", systemImage: "checkmark.circle") }.disabled(selected.isEmpty)
                Button { Task { await store.refreshFeed(podcast) } }
                    label: { Label("Refresh Feed", systemImage: "arrow.clockwise") }
            }
        }
        .overlay { if episodes.isEmpty { ProgressView() } }
        .task { await store.loadEpisodes(podcast) }
    }
}

// MARK: Add + Settings

struct AddPodcastView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Add Podcast").font(.headline)
            TextField("Search by name, or paste an RSS feed URL", text: $query)
                .textFieldStyle(.roundedBorder).onSubmit(go)
            List(results) { r in
                HStack {
                    Artwork(url: r.artwork, size: 40)
                    VStack(alignment: .leading) {
                        Text(r.title).lineLimit(1)
                        Text(r.author).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.podcasts.contains(where: { $0.feedUrl == r.feedUrl }) {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    } else {
                        Button("Subscribe") { Task { await store.subscribe(feedUrl: r.feedUrl) } }
                    }
                }
            }
            .frame(height: 300)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Search / Add", action: go).keyboardShortcut(.defaultAction).disabled(query.isEmpty)
            }
        }
        .padding().frame(width: 480)
    }

    private func go() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            if q.lowercased().hasPrefix("http") || q.lowercased().hasPrefix("feed:") {
                await store.subscribe(feedUrl: q); query = ""
            } else {
                results = await store.search(q)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server").font(.headline)
            TextField("https://example.com/podcasts", text: $store.serverURL).textFieldStyle(.roundedBorder)
            TextField("Username", text: $store.username).textFieldStyle(.roundedBorder)
            SecureField("Password", text: $store.password).textFieldStyle(.roundedBorder)
            Text("The password is stored in your macOS Keychain. Use an https:// URL.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save & Sync") {
                    store.saveSettings(); dismiss()
                    Task { await store.sync() }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding().frame(width: 420)
    }
}
