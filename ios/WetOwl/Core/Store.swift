import Foundation
import SwiftUI

/// What the screens show: the house's last answer straight from disk, then the fresh
/// one when it comes. Nothing waits on the network to draw.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var details: [Int: Playlist] = [:]
    @Published private(set) var home: HomePicks = HomePicks()
    @Published private(set) var history: [Track] = []
    @Published private(set) var queues: [QueueState] = []
    @Published private(set) var favourites: Set<Int> = []
    @Published private(set) var favouritesPlaylistId: Int?
    @Published private(set) var loadingPlaylists = false
    @Published private(set) var playlistsError: String?

    private let api: API
    private var lastRefresh = Date.distantPast

    init(api: API) {
        self.api = api
        if let d = DiskCache.read("playlists"), let v: Lossy<Playlist> = try? API.decode(d) { playlists = v.items }
        if let d = DiskCache.read("home"), let v: HomePicks = try? API.decode(d) { home = v }
        if let d = DiskCache.read("history"), let v: Lossy<Track> = try? API.decode(d) { history = v.items }
        if let d = DiskCache.read("queues"), let v: Lossy<QueueState> = try? API.decode(d) { queues = v.items }
        if let d = DiskCache.read("favourites"), let v: Favourites = try? API.decode(d) {
            favourites = Set(v.trackIds)
            favouritesPlaylistId = v.playlistId
        }
    }

    /// Everything the first screens need, all at once. Skipped when it ran a moment ago.
    func refreshAll(force: Bool = false) async {
        if !force && Date().timeIntervalSince(lastRefresh) < 20 { return }
        lastRefresh = Date()
        async let a: Void = refreshPlaylists()
        async let b: Void = refreshQueues()
        async let c: Void = refreshFavourites()
        async let d: Void = refreshHistory()
        async let e: Void = refreshHome()
        _ = await (a, b, c, d, e)
    }

    /// Fetch, decode off the main thread, keep the bytes for next time.
    private func fetch<T: Decodable>(_ path: String, key: String, query: [String: String] = [:]) async throws -> T {
        let (v, d): (T, Data) = try await api.fetch(path, query: query)
        DiskCache.write(key, d)
        return v
    }

    func refreshPlaylists() async {
        loadingPlaylists = true
        defer { loadingPlaylists = false }
        do {
            let v: Lossy<Playlist> = try await fetch("/playlists", key: "playlists")
            playlists = v.items
            playlistsError = nil
        } catch {
            playlistsError = APIError.from(error).message
        }
    }

    func refreshQueues() async {
        if let v: Lossy<QueueState> = try? await fetch("/queues", key: "queues") { queues = v.items }
    }

    func refreshHistory() async {
        if let v: Lossy<Track> = try? await fetch("/history", key: "history", query: ["limit": "30"]) {
            history = v.items
        }
    }

    func refreshHome() async {
        if let v: HomePicks = try? await fetch("/recommend/home", key: "home") { home = v }
    }

    func refreshFavourites() async {
        if let v: Favourites = try? await fetch("/favourites", key: "favourites") {
            favourites = Set(v.trackIds)
            favouritesPlaylistId = v.playlistId
        }
    }

    // MARK: One playlist

    func cachedPlaylist(_ id: Int) -> Playlist? {
        if let p = details[id] { return p }
        if let d = DiskCache.read("playlist-\(id)"), let p: Playlist = try? API.decode(d) {
            details[id] = p
            return p
        }
        return nil
    }

    @discardableResult
    func refreshPlaylist(_ id: Int) async throws -> Playlist {
        let p: Playlist = try await fetch("/playlists/\(id)", key: "playlist-\(id)")
        details[id] = p
        return p
    }

    // MARK: Favourites

    func isFavourite(_ id: Int) -> Bool { favourites.contains(id) }

    func toggleFavourite(_ id: Int) {
        let on = !favourites.contains(id)
        if on { favourites.insert(id) } else { favourites.remove(id) }
        Haptics.tap()
        Task {
            do {
                let now = try await api.setFavourite(id, on)
                if now != on {
                    if now { favourites.insert(id) } else { favourites.remove(id) }
                }
                if let pid = favouritesPlaylistId { details[pid] = nil; DiskCache.remove("playlist-\(pid)") }
            } catch {
                // Put it back as it was: the house did not take it.
                if on { favourites.remove(id) } else { favourites.insert(id) }
                AppModel.shared.say(APIError.from(error).message, icon: "exclamationmark.triangle")
            }
        }
    }

    func noteQueues(_ q: QueueState) {
        if let i = queues.firstIndex(where: { $0.id == q.id }) {
            var s = queues[i]
            s.cursorIndex = q.cursorIndex
            s.total = q.total
            queues[i] = s
        }
    }

    func clear() {
        playlists = []
        details = [:]
        home = HomePicks()
        history = []
        queues = []
        favourites = []
        favouritesPlaylistId = nil
        lastRefresh = .distantPast
    }
}
