import Foundation
import SwiftUI

enum APIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set the server URL and login in Settings first."
        case .http(let code, let detail): return "Server said \(code)\(detail.isEmpty ? "" : ": \(detail)")"
        }
    }
}

/// Downloads one file to `dest`. Only moves the file into place if the whole download succeeded.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let onProgress: @Sendable (Double) -> Void
    private var cont: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    init(dest: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.dest = dest; self.onProgress = onProgress
    }

    func run(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            cont = c
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            s.downloadTask(with: url).resume()
            s.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten w: Int64, totalBytesExpectedToWrite total: Int64) {
        if total > 0 { onProgress(min(Double(w) / Double(total), 1)) }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        if let h = t.response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            moveError = APIError.http(h.statusCode, "download failed"); return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: loc, to: dest)
        } catch { moveError = error }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let c = cont else { return }
        cont = nil
        if let e = error ?? moveError { c.resume(throwing: e) } else { c.resume() }
    }
}

@MainActor
final class Store: ObservableObject {
    // Settings
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    @Published var username: String = UserDefaults.standard.string(forKey: "username") ?? ""
    @Published var password: String = Keychain.get("password") ?? ""

    // Mirrored server state (the web is the source of truth)
    @Published var podcasts: [Podcast] = []
    @Published var queue: [Episode] = []
    @Published var showEpisodes: [Int: [Episode]] = [:]

    // UI state
    @Published var progress: [Int: Double] = [:]      // episode.id -> 0...1
    @Published var syncing = false
    @Published var downloading = false
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var diskTick = 0                       // bump to re-check files on disk

    var isConfigured: Bool { !serverURL.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty }

    func saveSettings() {
        serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        UserDefaults.standard.set(username, forKey: "username")
        Keychain.set(password, account: "password")
    }

    // MARK: HTTP

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard isConfigured else { throw APIError.notConfigured }
        var base = serverURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        let cred = Data("\(username):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(cred)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String ?? ""
            throw APIError.http(h.statusCode, detail)
        }
        return data
    }

    private func decode<T: Decodable>(_ t: T.Type, _ data: Data) throws -> T {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(T.self, from: data)
    }

    private func report(_ e: Error) { errorMessage = e.localizedDescription }

    // MARK: Sync (pull: web wins)

    private struct StateDTO: Decodable { var podcasts: [Podcast]; var queue: [Episode] }

    func sync() async {
        guard isConfigured else { return }
        syncing = true; defer { syncing = false }
        do {
            let s = try decode(StateDTO.self, try await send("GET", "/api/state"))
            podcasts = s.podcasts; queue = s.queue
            let live = Set(s.podcasts.map(\.id))
            showEpisodes = showEpisodes.filter { live.contains($0.key) }
        } catch { report(error) }
    }

    func loadEpisodes(_ p: Podcast) async {
        do { showEpisodes[p.id] = try decode([Episode].self, try await send("GET", "/api/podcasts/\(p.id)/episodes?limit=500")) }
        catch { report(error) }
    }

    func refreshFeed(_ p: Podcast) async {
        do { _ = try await send("POST", "/api/podcasts/\(p.id)/refresh"); await loadEpisodes(p); await sync() }
        catch { report(error) }
    }

    // MARK: Push local changes back to the web

    func setState(_ ids: [Int], _ state: String, in p: Podcast? = nil) async {
        guard !ids.isEmpty else { return }
        do {
            _ = try await send("POST", "/api/episodes/state", body: ["ids": ids, "state": state])
            await sync()
            if let p { await loadEpisodes(p) }
        } catch { report(error) }
    }

    func moveQueue(from: IndexSet, to: Int) async {
        queue.move(fromOffsets: from, toOffset: to)               // optimistic
        do { _ = try await send("PUT", "/api/queue/order", body: ["ids": queue.map(\.id)]) }
        catch { report(error); await sync() }
    }

    func movePodcasts(from: IndexSet, to: Int) async {
        podcasts.move(fromOffsets: from, toOffset: to)
        do { _ = try await send("PUT", "/api/podcasts/order", body: ["ids": podcasts.map(\.id)]) }
        catch { report(error); await sync() }
    }

    func search(_ term: String) async -> [SearchResult] {
        let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        do { return try decode([SearchResult].self, try await send("GET", "/api/search?q=\(q)")) }
        catch { report(error); return [] }
    }

    func subscribe(feedUrl: String) async {
        do { _ = try await send("POST", "/api/podcasts", body: ["feed_url": feedUrl]); await sync() }
        catch { report(error) }
    }

    func unsubscribe(_ p: Podcast) async {
        do { _ = try await send("DELETE", "/api/podcasts/\(p.id)"); await sync() }
        catch { report(error) }
    }

    // MARK: Download queue -> ~/Podcasts, then mark read on the web

    func isOnDisk(_ e: Episode) -> Bool {
        _ = diskTick
        return FileManager.default.fileExists(atPath: Paths.fileURL(for: e).path)
    }

    func downloadQueue() async {
        guard !downloading else { return }
        await sync()                                   // web is the source of truth: start from its queue
        let items = queue
        guard !items.isEmpty else { status = "Queue is empty."; return }
        downloading = true; defer { downloading = false }

        var done = 0
        var failures: [String] = []
        let fm = FileManager.default

        for (i, e) in items.enumerated() {
            status = "Downloading \(i + 1) of \(items.count): \(e.title)"
            let dest = Paths.fileURL(for: e)
            if !fm.fileExists(atPath: dest.path) {                // already on disk? just mark it read
                guard let url = URL(string: e.enclosureUrl) else { failures.append("\(e.title): bad URL"); continue }
                progress[e.id] = 0
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let id = e.id
                    try await FileDownloader(dest: dest) { p in
                        Task { @MainActor [weak self] in self?.progress[id] = p }
                    }.run(url)
                } catch {
                    progress[e.id] = nil
                    failures.append("\(e.title): \(error.localizedDescription)")
                    continue                                       // not marked read; stays queued on the web
                }
                progress[e.id] = nil
                diskTick += 1
            }
            do {
                _ = try await send("PATCH", "/api/episodes/\(e.id)", body: ["state": "read"])
                done += 1
            } catch {
                failures.append("\(e.title): downloaded, but couldn't mark read (\(error.localizedDescription))")
            }
        }

        await sync()
        status = "Done: \(done) downloaded and marked read" + (failures.isEmpty ? "." : ", \(failures.count) failed.")
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }
}
