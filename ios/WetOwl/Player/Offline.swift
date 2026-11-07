import Combine
import Foundation
import UIKit

/// iOS hands a finished background session back to the app through the delegate;
/// the completion handler waits here until the session has said everything.
enum BackgroundDownloads {
    static let identifier = "dance.duckduck.wetowl.downloads"
    private static let lock = NSLock()
    private static var _completion: (() -> Void)?

    static var completion: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _completion }
        set { lock.lock(); _completion = newValue; lock.unlock() }
    }
}

/// Playlists kept on the phone. Their songs' audio is fetched in a background
/// session (it carries on with the app away) and played from disk from then on.
@MainActor
final class Offline: ObservableObject {
    struct Kept: Codable, Identifiable, Hashable {
        var id: Int
        var name: String
        var trackIds: [Int]
    }

    private struct Index: Codable {
        var kept: [Kept] = []
        var files: [String: Int64] = [:]
    }

    @Published private(set) var kept: [Kept] = []
    @Published private(set) var files: [Int: Int64] = [:]
    @Published private(set) var active: Set<Int> = []
    @Published private(set) var failed: [Int: String] = [:]
    @Published var allowCellular: Bool {
        didSet { UserDefaults.standard.set(allowCellular, forKey: "wo.cellular") }
    }

    let dir: URL
    private let listsDir: URL
    private let indexFile: URL
    private let api: API
    private var session: URLSession!
    private let delegate = DownloadDelegate()
    private var waiting: [Int] = []
    private let window = 6

    init(api: API) {
        self.api = api
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Offline", isDirectory: true)
        dir = base.appendingPathComponent("audio", isDirectory: true)
        listsDir = base.appendingPathComponent("lists", isDirectory: true)
        indexFile = base.appendingPathComponent("index.json")
        allowCellular = UserDefaults.standard.object(forKey: "wo.cellular") as? Bool ?? true
        for d in [base, dir, listsDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        var b = base
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? b.setResourceValues(rv)

        loadIndex()

        delegate.dir = dir
        delegate.owner = self
        let c = URLSessionConfiguration.background(withIdentifier: BackgroundDownloads.identifier)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.httpMaximumConnectionsPerHost = 4
        c.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)

        // Tasks still running from before the app was last stopped.
        session.getAllTasks { tasks in
            let ids = tasks.compactMap { Int($0.taskDescription ?? "") }
            Task { @MainActor in
                self.active.formUnion(ids)
                self.pump()
            }
        }
    }

    // MARK: What is here

    func has(_ trackId: Int) -> Bool { files[trackId] != nil }

    func fileURL(_ trackId: Int) -> URL? {
        guard files[trackId] != nil else { return nil }
        return dir.appendingPathComponent("\(trackId).m4a")
    }

    func isKept(_ playlistId: Int) -> Bool { kept.contains { $0.id == playlistId } }

    var totalBytes: Int64 { files.values.reduce(0, +) }

    /// For one kept playlist: songs here, songs wanted.
    func progress(_ playlistId: Int) -> (have: Int, want: Int)? {
        guard let k = kept.first(where: { $0.id == playlistId }) else { return nil }
        return (k.trackIds.filter { files[$0] != nil }.count, k.trackIds.count)
    }

    /// The playlist as it was when it was kept: what the list shows with no signal.
    func savedList(_ playlistId: Int) -> Playlist? {
        guard let d = try? Data(contentsOf: listsDir.appendingPathComponent("\(playlistId).json")) else { return nil }
        return try? API.decode(d)
    }

    // MARK: Keeping

    func keep(_ playlistId: Int, name: String) {
        if !isKept(playlistId) {
            kept.append(Kept(id: playlistId, name: name, trackIds: []))
            saveIndex()
        }
        Haptics.done()
        Task { await refresh(playlistId) }
    }

    func unkeep(_ playlistId: Int) {
        kept.removeAll { $0.id == playlistId }
        try? FileManager.default.removeItem(at: listsDir.appendingPathComponent("\(playlistId).json"))
        saveIndex()
        prune()
    }

    /// Every kept list fetched again: new songs come down, removed ones go.
    func syncAll() async {
        for k in kept { await refresh(k.id) }
        prune()
    }

    private func refresh(_ playlistId: Int) async {
        guard let answer: (Playlist, Data) = try? await api.fetch("/playlists/\(playlistId)") else { return }
        let (p, raw) = answer
        guard let i = kept.firstIndex(where: { $0.id == playlistId }) else { return }
        let ready = (p.tracks ?? []).filter { $0.isReady }
        kept[i].name = p.name
        kept[i].trackIds = ready.map { $0.id }
        try? raw.write(to: listsDir.appendingPathComponent("\(playlistId).json"), options: .atomic)
        saveIndex()
        for t in ready where files[t.id] == nil && !active.contains(t.id) && !waiting.contains(t.id) {
            waiting.append(t.id)
        }
        failed = failed.filter { !waiting.contains($0.key) }
        pump()
    }

    /// Start the next downloads, a few at a time.
    private func pump() {
        while active.count < window, !waiting.isEmpty {
            let id = waiting.removeFirst()
            if files[id] != nil || active.contains(id) { continue }
            guard let url = api.url("/tracks/\(id)/stream") else { continue }
            var r = api.authorized(url)
            r.allowsCellularAccess = allowCellular
            let task = session.downloadTask(with: r)
            task.taskDescription = String(id)
            active.insert(id)
            task.resume()
        }
    }

    /// Audio no kept list wants any more goes.
    private func prune() {
        let wanted = Set(kept.flatMap { $0.trackIds })
        waiting.removeAll { !wanted.contains($0) }
        for id in Array(files.keys) where !wanted.contains(id) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).m4a"))
            files[id] = nil
        }
        saveIndex()
    }

    func removeAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        kept = []
        files = [:]
        waiting = []
        active = []
        failed = [:]
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: listsDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: listsDir, withIntermediateDirectories: true)
        saveIndex()
    }

    // MARK: From the session

    fileprivate func finished(_ id: Int, bytes: Int64) {
        active.remove(id)
        failed[id] = nil
        files[id] = bytes
        saveIndex()
        pump()
    }

    fileprivate func failedDownload(_ id: Int, _ why: String) {
        active.remove(id)
        failed[id] = why
        Log.shared.add("download \(id) failed: \(why)")
        pump()
    }

    // MARK: Index

    private func loadIndex() {
        guard let d = try? Data(contentsOf: indexFile), let i = try? JSONDecoder().decode(Index.self, from: d) else { return }
        kept = i.kept
        var f: [Int: Int64] = [:]
        for (k, v) in i.files {
            guard let id = Int(k) else { continue }
            // Only what is really on disk.
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).m4a").path) { f[id] = v }
        }
        files = f
    }

    private func saveIndex() {
        var f: [String: Int64] = [:]
        for (k, v) in files { f[String(k)] = v }
        let i = Index(kept: kept, files: f)
        if let d = try? JSONEncoder().encode(i) { try? d.write(to: indexFile, options: .atomic) }
    }
}

/// URLSession's delegate. Not on the main actor: the file has to be moved before the
/// callback returns, then the news goes to Offline.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var dir: URL?
    weak var owner: Offline?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = Int(downloadTask.taskDescription ?? ""), let dir = dir else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let owner = self.owner
        guard status == 200 || status == 206 else {
            Task { @MainActor in owner?.failedDownload(id, "HTTP \(status)") }
            return
        }
        let dest = dir.appendingPathComponent("\(id).m4a")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
            Task { @MainActor in owner?.finished(id, bytes: size) }
        } catch {
            let why = error.localizedDescription
            Task { @MainActor in owner?.failedDownload(id, why) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let id = Int(task.taskDescription ?? "") else { return }
        let why = error.localizedDescription
        let owner = self.owner
        Task { @MainActor in owner?.failedDownload(id, why) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            BackgroundDownloads.completion?()
            BackgroundDownloads.completion = nil
        }
    }
}
