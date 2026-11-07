import Combine
import Foundation
import SwiftUI
import UIKit

/// Where a tab's navigation can go.
enum Route: Hashable {
    case playlist(PlaylistRef)
    case artist(String)
    case album(AlbumRef)
    case artists
    case albums
    case songs
}

/// Each tab's navigation, so anything (the player sheet, a menu) can open a page.
@MainActor
final class Router: ObservableObject {
    @Published var home = NavigationPath()
    @Published var search = NavigationPath()
    @Published var library = NavigationPath()

    func push(_ r: Route, on tab: AppModel.Tab) {
        switch tab {
        case .home: home.append(r)
        case .search: search.append(r)
        case .library: library.append(r)
        }
    }

    func popToRoot(_ tab: AppModel.Tab) {
        switch tab {
        case .home: home = NavigationPath()
        case .search: search = NavigationPath()
        case .library: library = NavigationPath()
        }
    }
}

/// The house talking back: queue changes made elsewhere, songs arriving, other devices
/// asking this one to play. A server-sent event stream, held while the app is in front
/// or playing, reconnected with backoff.
@MainActor
final class Live: ObservableObject {
    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var myId: Int?
    @Published private(set) var connected = false

    private let api: API
    private var task: Task<Void, Never>?
    weak var player: Player?
    weak var store: Store?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 90       // the house says something every 20 s
        c.timeoutIntervalForResource = 24 * 3600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    init(api: API) {
        self.api = api
    }

    var others: [DeviceInfo] { devices.filter { !$0.isThis && $0.id != myId } }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
        connected = false
    }

    private func loop() async {
        var wait: UInt64 = 2
        while !Task.isCancelled {
            if myId == nil { await refreshDevices() }
            do {
                try await listen()
                wait = 2
            } catch {
                if !Task.isCancelled { Log.shared.add("live: \(APIError.from(error).message)") }
            }
            connected = false
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            wait = min(wait * 2, 60)
        }
    }

    private func listen() async throws {
        guard let url = api.url("/events") else { return }
        var req = api.authorized(url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await Live.session.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 { api.onUnauthorized?() }
            throw APIError(status: status, message: "events answered \(status)")
        }
        connected = true
        var event = ""
        for try await line in bytes.lines {
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                handle(event, Data(payload.utf8))
                event = ""
            }
        }
    }

    private func handle(_ event: String, _ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        func int(_ k: String) -> Int? { (obj[k] as? NSNumber)?.intValue }
        switch event {
        case "queue_changed":
            if let q = int("queue_id") { player?.houseChanged(queue: q, rev: int("rev")) }
        case "track_ready":
            if let t = int("track_id") {
                player?.trackReady(t)
                store?.markReady(t)
            }
        case "device_command":
            let action = obj["action"] as? String ?? ""
            if action == "yield" {
                if int("except") != myId { player?.yieldToOther() }
                return
            }
            guard let me = myId, int("to") == me else { return }
            // Our own "play here": done already, before it was sent.
            if action == "take" && int("from") == me { return }
            Log.shared.add("live: asked to \(action)")
            player?.perform(action, queueId: int("queue_id"), trackId: int("track_id"),
                            positionMs: int("position_ms") ?? 0)
        case "devices":
            Task { await refreshDevices() }
        default:
            break
        }
    }

    func refreshDevices() async {
        guard let d = try? await api.devices() else { return }
        devices = d.devices
        if let me = d.this { myId = me }
    }

    // MARK: Moving the music

    /// What another device is playing, here, from where it has got to.
    func playHere(_ d: DeviceInfo) {
        guard let player = player, let qid = d.queueId, let t = d.track else { return }
        let at = d.positionMs + (d.playing ? d.ageMs : 0)
        player.takeOver(queueId: qid, trackId: t.id, positionMs: at)
        guard let me = myId else { return }
        Task {
            try? await api.command(me, "take", queueId: qid, trackId: t.id, positionMs: at)
            await refreshDevices()
        }
    }

    /// What plays here, on another device.
    func playThere(_ d: DeviceInfo) {
        guard let player = player, let q = player.queue, q.id > 0, let t = player.current else { return }
        let at = Int(player.clock.elapsed * 1000)
        player.pause()
        Haptics.done()
        AppModel.shared.say("Playing on \(d.name)", icon: d.icon)
        Task {
            do {
                try await api.command(d.id, "take", queueId: q.id, trackId: t.id, positionMs: at)
            } catch {
                AppModel.shared.say(APIError.from(error).message, icon: "exclamationmark.triangle")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshDevices()
        }
    }

    /// Play, pause, skip on another device.
    func remote(_ d: DeviceInfo, _ action: String) {
        Haptics.tap()
        Task {
            try? await api.command(d.id, action)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await refreshDevices()
        }
    }
}

/// A newer build of this app on GitHub, installable through SideStore.
@MainActor
final class Updates: ObservableObject {
    struct Release: Equatable {
        let version: String
        let build: String
        let ipa: URL
        let page: URL
    }

    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?

    func check(force: Bool = false) async {
        if !force, let l = lastChecked, Date().timeIntervalSince(l) < 6 * 3600 { return }
        checking = true
        defer { checking = false }
        guard let url = URL(string: "https://api.github.com/repos/MCDuckler/muse/releases?per_page=20") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("WetOwl-iOS", forHTTPHeaderField: "User-Agent")
        guard let answer = try? await LiveTransport.session.data(for: req) else { return }
        let (data, response) = answer
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        lastChecked = Date()
        for r in list {
            guard let tag = r["tag_name"] as? String, tag.hasPrefix("ios2-") else { continue }
            // ios2-<version>-<build>
            let parts = tag.split(separator: "-")
            guard parts.count >= 3 else { continue }
            let build = String(parts[parts.count - 1])
            let version = String(parts[1])
            let assets = r["assets"] as? [[String: Any]] ?? []
            guard let ipaString = assets.first(where: { ($0["name"] as? String) == "WetOwl.ipa" })?["browser_download_url"] as? String,
                  let ipa = URL(string: ipaString),
                  let page = URL(string: r["html_url"] as? String ?? "") else { continue }
            available = Updates.isNewer(build, than: Build.number) ? Release(version: version, build: build, ipa: ipa, page: page) : nil
            return
        }
    }

    nonisolated static func isNewer(_ build: String, than mine: String) -> Bool {
        guard let b = Int(build) else { return false }
        return b > (Int(mine) ?? 0) && mine.count >= 8
    }

    /// SideStore installs it straight from the link; without SideStore, the release page.
    func install() {
        guard let r = available else { return }
        var c = URLComponents()
        c.scheme = "sidestore"
        c.host = "install"
        c.queryItems = [URLQueryItem(name: "url", value: r.ipa.absoluteString)]
        guard let link = c.url else { return }
        UIApplication.shared.open(link, options: [:]) { ok in
            if !ok { UIApplication.shared.open(r.page) }
        }
    }
}
