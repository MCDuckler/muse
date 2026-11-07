import Combine
import Foundation
import Network
import Security
import UIKit

enum Keys {
    static let server = "wo.server"
    static let user = "wo.user"
    static let activeQueue = "wo.activeQueue"
    static let recentSearches = "wo.recentSearches"
    static let jamListening = "wo.jamListening"
    static let jamHostedHere = "wo.jamHostedHere"
}

@MainActor
enum Build {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var number: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    static var device: String {
        "iPhone native \(UIDevice.current.systemVersion) \(Int(UIScreen.main.bounds.width))x\(Int(UIScreen.main.bounds.height))"
    }
}

/// What the app did, newest last, kept small. Sent to the house's playback reports on
/// demand and after trouble, which is the only way to see what happened on a phone.
final class Log: @unchecked Sendable {
    static let shared = Log()

    private let lock = NSLock()
    private var lines: [String] = []
    private let max = 400
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func add(_ s: String) {
        lock.lock()
        let line = "\(stamp.string(from: Date())) \(s)"
        lines.append(line)
        if lines.count > max { lines.removeFirst(lines.count - max) }
        lock.unlock()
        #if DEBUG
        print(line)
        #endif
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

enum Keychain {
    private static let service = "dance.duckduck.wetowl"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            // Readable while locked after the first unlock: a lock-screen skip needs it.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// The house's last answers, kept on disk so every screen opens with something on it
/// and still has it with no signal.
enum DiskCache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("api", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static let queue = DispatchQueue(label: "wo.diskcache", qos: .utility)

    private static func file(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return dir.appendingPathComponent(String(safe) + ".json")
    }

    static func read(_ key: String) -> Data? {
        try? Data(contentsOf: file(key))
    }

    static func write(_ key: String, _ data: Data) {
        let f = file(key)
        queue.async { try? data.write(to: f, options: .atomic) }
    }

    static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: file(key))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Whether there is any network at all.
final class Reachability: ObservableObject {
    @Published private(set) var online = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self = self, self.online != ok else { return }
                self.online = ok
                Log.shared.add("network \(ok ? "up" : "down")")
            }
        }
        monitor.start(queue: DispatchQueue(label: "wo.reachability"))
    }
}

/// Plays heard while offline (or while the house was away), sent when it is back.
/// Kept on disk so a listen survives the app being killed.
final class Outbox: @unchecked Sendable {
    struct Listen: Codable {
        var trackId: Int
        var ms: Int
        var completed: Bool
    }

    private let lock = NSLock()
    private var pending: [Listen] = []
    private var sending = false
    private let file: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("outbox.json")
    }()

    init() {
        if let d = try? Data(contentsOf: file), let l = try? JSONDecoder().decode([Listen].self, from: d) {
            pending = l
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(pending) { try? d.write(to: file, options: .atomic) }
    }

    func add(_ l: Listen) {
        locked {
            pending.append(l)
            if pending.count > 500 { pending.removeFirst(pending.count - 500) }
            save()
        }
    }

    var count: Int { locked { pending.count } }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    /// The listens to send, or nil when there are none or a send is under way.
    private func take() -> [Listen]? {
        locked {
            if sending || pending.isEmpty { return nil }
            sending = true
            return pending
        }
    }

    private func done(_ sent: Int) {
        locked {
            pending.removeFirst(min(sent, pending.count))
            save()
            sending = false
        }
    }

    func flush(_ api: API) async {
        guard let batch = take() else { return }
        var sent = 0
        for l in batch {
            do {
                try await api.listen(trackId: l.trackId, ms: l.ms, completed: l.completed)
                sent += 1
            } catch let e as APIError where e.status == 404 || e.status == 400 {
                sent += 1   // the house will never take this one; drop it
            } catch {
                break
            }
        }
        done(sent)
    }
}

extension String {
    /// "#8a8a8a" → components.
    var hexRGB: (Double, Double, Double)? {
        var s = self
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
