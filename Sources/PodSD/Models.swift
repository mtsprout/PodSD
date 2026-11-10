import Foundation
import Security

// Mirrors the server's JSON (decoded with .convertFromSnakeCase).

struct Episode: Codable, Identifiable, Hashable {
    var id: Int
    var podcastId: Int
    var podcastTitle: String
    var guid: String
    var title: String
    var pubDate: Int?
    var enclosureUrl: String
    var mime: String?
    var size: Int64?
    var state: String          // new | queued | read
    var queuePos: Int?

    var date: Date? { pubDate.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    /// File extension for the saved file. The player only reliably handles MP3.
    var fileExtension: String {
        let ext = (URL(string: enclosureUrl)?.pathExtension ?? "").lowercased()
        if !ext.isEmpty, ext.count <= 4 { return ext }
        switch mime?.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        default: return "mp3"
        }
    }
    var isMP3: Bool { fileExtension == "mp3" }
}

enum Paths {
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Podcasts", isDirectory: true)
    }

    /// Where downloads go: the folder chosen in the Download Queue dialog (a folder on this Mac, or the
    /// player's card), remembered between runs. Falls back to ~/Podcasts.
    static var downloadsRoot: URL {
        if let p = UserDefaults.standard.string(forKey: "destination"), !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return defaultRoot
    }

    static func setDestination(_ url: URL) { UserDefaults.standard.set(url.path, forKey: "destination") }

    /// Makes a name safe for a FAT32 microSD card (no / \ : * ? " < > |), and not too long.
    static func safeName(_ s: String, max: Int = 80) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var out = s.components(separatedBy: bad).joined(separator: " ")
        out = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if out.count > max { out = String(out.prefix(max)).trimmingCharacters(in: .whitespaces) }
        return out.isEmpty ? "Untitled" : out
    }

    static func folder(forShow title: String) -> URL {
        downloadsRoot.appendingPathComponent(safeName(title, max: 60), isDirectory: true)
    }

    /// Date-prefixed so alphabetical order == chronological order on a screen-free player.
    static func fileURL(for e: Episode) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let prefix = e.date.map { df.string(from: $0) } ?? "0000-00-00"
        if useSubfolders {
            let name = safeName("\(prefix) - \(e.title)")
            return folder(forShow: e.podcastTitle).appendingPathComponent(name).appendingPathExtension(e.fileExtension)
        }
        // Flat: one folder, "<Show> - <date> - <title>.mp3". Unknown whether the player supports subfolders.
        let name = safeName("\(safeName(e.podcastTitle, max: 30)) - \(prefix) - \(safeName(e.title, max: 70))", max: 130)
        return downloadsRoot.appendingPathComponent(name).appendingPathExtension(e.fileExtension)
    }

    /// Setup toggle (off by default). On: ~/Podcasts/<Show>/<date - title>.mp3. Off: one flat folder, for
    /// players without subfolder support.
    static var useSubfolders: Bool { UserDefaults.standard.bool(forKey: "useSubfolders") }
}

/// Minimal Keychain wrapper so the server password isn't stored in plain preferences.
enum Keychain {
    private static let service = "local.podsd"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
