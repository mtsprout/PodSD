import SwiftUI
import AppKit

func reveal(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var showSettings = false

    private var connection: String {
        guard store.isConfigured else { return "Not set up" }
        let host = URL(string: store.serverURL)?.host ?? store.serverURL
        return "\(store.username) @ \(host)"
    }

    private var summary: String {
        guard !store.queue.isEmpty else { return "" }
        let bytes = store.queue.compactMap(\.size).reduce(0, +)
        let n = store.queue.count
        return "\(n) episode\(n == 1 ? "" : "s")" + (bytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PodSD").font(.title2.bold())
                    Text(connection).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.syncing { ProgressView().controlSize(.small) }
                Button { Task { await store.sync(); if store.errorMessage == nil { store.status = "Synced." } } } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.syncing || store.downloading || !store.isConfigured)
                Button { showSettings = true } label: { Label("Setup", systemImage: "gearshape") }
            }
            .padding(12)
            Divider()

            List(store.queue) { e in QueueRow(episode: e) }
                .overlay {
                    if !store.isConfigured {
                        ContentUnavailableView("Set up your server", systemImage: "gearshape",
                                               description: Text("Click Setup and enter the server URL and login."))
                    } else if store.queue.isEmpty {
                        ContentUnavailableView("Nothing queued", systemImage: "tray",
                                               description: Text("Queue episodes on the web, then click Sync."))
                    }
                }

            Divider()
            HStack {
                Text(store.status.isEmpty ? summary : store.status)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { reveal(Paths.downloadsRoot) } label: { Label("Open Folder", systemImage: "folder") }
                Button { Task { await store.downloadQueue() } } label: {
                    Label("Download Queue", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.downloading || store.queue.isEmpty)
            }
            .padding(12)
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .alert("Error", isPresented: .constant(store.errorMessage != nil)) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .frame(minWidth: 560, minHeight: 420)
        .task {
            if store.isConfigured { await store.sync() } else { showSettings = true }
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
                HStack(spacing: 8) {
                    Text(episode.podcastTitle)
                    if let d = episode.date { Text(d.formatted(date: .abbreviated, time: .omitted)) }
                    if let s = episode.size, s > 0 { Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
                    if !episode.isMP3 {
                        Label("\(episode.fileExtension.uppercased()) – may not play", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = store.progress[episode.id] {
                ProgressView(value: p).frame(width: 90)
            } else if store.isOnDisk(episode) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Already on disk")
            }
        }
        .padding(.vertical, 2)
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

            Divider()
            Text("Files").font(.headline)
            Toggle("Use subfolders (one folder per show)", isOn: $store.useSubfolders)
            Text(store.useSubfolders
                 ? "Saves to ~/Podcasts/<Show>/<date - title>.mp3"
                 : "Saves everything flat in ~/Podcasts as <Show> - <date> - <title>.mp3. Use this if your player doesn't read subfolders.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Already-downloaded files aren't moved when you switch; queued episodes would download again in the new layout.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { store.revertSettings(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save & Sync") {
                    store.saveSettings(); dismiss()
                    Task { await store.sync() }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding().frame(width: 420)
    }
}
