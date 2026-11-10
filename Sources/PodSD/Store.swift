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

/// The Mac side is deliberately small: set up the server, sync the queue from the web, download it.
/// Everything else (browsing, subscribing, queueing, ordering) happens on the web, which is the source of truth.
@MainActor
final class Store: ObservableObject {
    // Settings
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    @Published var username: String = UserDefaults.standard.string(forKey: "username") ?? ""
    @Published var password: String = Keychain.get("password") ?? ""
    @Published var useSubfolders: Bool = UserDefaults.standard.bool(forKey: "useSubfolders")
    @Published var destination: URL = Paths.downloadsRoot      // chosen in the Download Queue dialog

    // Mirrored from the server
    @Published var queue: [Episode] = []

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
        UserDefaults.standard.set(useSubfolders, forKey: "useSubfolders")
        diskTick += 1                                 // the layout decides where "already on disk" looks
    }

    /// Discards unsaved edits in the Setup sheet.
    func revertSettings() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        username = UserDefaults.standard.string(forKey: "username") ?? ""
        password = Keychain.get("password") ?? ""
        useSubfolders = UserDefaults.standard.bool(forKey: "useSubfolders")
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

    // MARK: Sync (pull: web wins)

    private struct StateDTO: Decodable { var queue: [Episode] }

    /// Pulls the current queue from the web. Returns false (and sets `errorMessage`) if it couldn't.
    @discardableResult
    func sync() async -> Bool {
        guard isConfigured else { return false }
        syncing = true; defer { syncing = false }
        do {
            let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
            queue = try d.decode(StateDTO.self, from: try await send("GET", "/api/state")).queue
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Destination (this Mac or the player's card)

    func setDestination(_ url: URL) {
        Paths.setDestination(url)
        destination = url
        diskTick += 1                                  // "already on disk" now looks in the new place
    }

    /// Mounted external volumes (an SD card in a reader, a player in USB-storage mode).
    static func externalVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return vols.filter { u in
            u.path.hasPrefix("/Volumes/") && ((try? u.resourceValues(forKeys: Set(keys)))?.volumeIsInternal == false)
        }
    }

    /// Bytes still to download (queued episodes not already in the destination), by the feed's stated sizes.
    func bytesNeeded() -> Int64 { queue.filter { !isOnDisk($0) }.compactMap(\.size).reduce(0, +) }

    func bytesAvailable(at url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: Download queue -> chosen destination, then mark read on the web

    func isOnDisk(_ e: Episode) -> Bool {
        _ = diskTick
        return FileManager.default.fileExists(atPath: Paths.fileURL(for: e).path)
    }

    func downloadQueue() async {
        guard !downloading else { return }
        guard await sync() else { return }             // web is the source of truth: start from its queue
        let items = queue
        guard !items.isEmpty else { status = "Queue is empty."; return }

        // The default folder is created on demand; anything else (e.g. the player's card) must already be there.
        let fm0 = FileManager.default
        if destination.path == Paths.defaultRoot.path { try? fm0.createDirectory(at: destination, withIntermediateDirectories: true) }
        var isDir: ObjCBool = false
        guard fm0.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = "“\(destination.lastPathComponent)” isn't available. Is the player or card plugged in?"
            return
        }
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
        status = "Done: \(done) saved to “\(destination.lastPathComponent)” and marked read" + (failures.isEmpty ? "." : ", \(failures.count) failed.")
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }
}
