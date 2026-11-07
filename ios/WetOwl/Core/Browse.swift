import Foundation

// The rest of the house's answers: lyrics, artists and records, the library's lists,
// devices. Same rules as Models.swift: optional where it can be, lossy lists.

struct LyricsAnswer: Decodable {
    var synced: String?
    var plain: String?

    enum CodingKeys: String, CodingKey { case synced, plain }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        synced = c.opt(String.self, .synced)
        plain = c.opt(String.self, .plain)
    }
}

struct LyricLine: Hashable, Identifiable {
    let id: Int
    let time: Double
    let text: String
}

enum LyricsParser {
    /// "[01:02.34] words" lines, several stamps allowed on one line; sorted by time.
    static func parse(_ lrc: String) -> [LyricLine] {
        var out: [(Double, String)] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var line = Substring(raw)
            var stamps: [Double] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let inner = line[line.index(after: line.startIndex)..<close]
                if let t = seconds(inner) { stamps.append(t) }
                line = line[line.index(after: close)...]
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            for t in stamps { out.append((t, text)) }
        }
        out.sort { $0.0 < $1.0 }
        return out.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// "mm:ss.xx" → seconds; anything else (an [ar:…] tag) → nil.
    static func seconds(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
        return m * 60 + sec
    }

    /// The line sung at [t]: the last one that has started.
    static func index(of lines: [LyricLine], at t: Double) -> Int? {
        var lo = 0
        var hi = lines.count - 1
        var found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t + 0.15 {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }
}

struct Page<Item: Decodable>: Decodable {
    var items: [Item]
    var total: Int

    enum CodingKeys: String, CodingKey { case items, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.opt(Lossy<Item>.self, .items)?.items ?? []
        total = c.opt(Int.self, .total) ?? items.count
    }
}

struct AlbumSummary: Decodable, Hashable, Identifiable {
    var name: String
    var artist: String
    var tracks: Int
    var year: Int?
    var coverUrl: String?
    var durationMs: Int?

    var id: String { artist + "\u{1}" + name }

    enum CodingKeys: String, CodingKey { case name, artist, tracks, year, coverUrl, durationMs }

    init(name: String, artist: String, tracks: Int = 0, coverUrl: String? = nil) {
        self.name = name
        self.artist = artist
        self.tracks = tracks
        self.coverUrl = coverUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        artist = c.opt(String.self, .artist) ?? "Unknown artist"
        tracks = c.opt(Int.self, .tracks) ?? 0
        year = c.opt(Int.self, .year)
        coverUrl = c.opt(String.self, .coverUrl)
        durationMs = c.opt(Int.self, .durationMs)
    }
}

struct ArtistSummary: Decodable, Hashable, Identifiable {
    var name: String
    var tracks: Int
    var albums: Int
    var coverUrl: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, tracks, albums, coverUrl }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        tracks = c.opt(Int.self, .tracks) ?? 0
        albums = c.opt(Int.self, .albums) ?? 0
        coverUrl = c.opt(String.self, .coverUrl)
    }
}

struct ArtistDetail: Decodable {
    struct Info: Decodable {
        var name: String
        var image: String?
        var fans: Int?
        var unavailable: String?

        enum CodingKeys: String, CodingKey { case name, image, fans, unavailable }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.opt(String.self, .name) ?? ""
            image = c.opt(String.self, .image)
            fans = c.opt(Int.self, .fans)
            unavailable = c.opt(String.self, .unavailable)
        }
    }

    /// A record of theirs out in the world, and how much of it is here.
    struct Release: Decodable, Hashable, Identifiable {
        var remoteId: String
        var title: String
        var cover: String?
        var releaseDate: String?
        var recordType: String?
        var tracks: Int?
        var have: Int

        var id: String { remoteId }
        var year: String? { releaseDate.map { String($0.prefix(4)) } }

        enum CodingKeys: String, CodingKey { case remoteId, title, cover, releaseDate, recordType, tracks, have }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            remoteId = try c.decode(String.self, forKey: .remoteId)
            title = c.opt(String.self, .title) ?? ""
            cover = c.opt(String.self, .cover)
            releaseDate = c.opt(String.self, .releaseDate)
            recordType = c.opt(String.self, .recordType)
            tracks = c.opt(Int.self, .tracks)
            have = c.opt(Int.self, .have) ?? 0
        }
    }

    /// One of their most played songs, and the copy here if there is one.
    struct Top: Decodable, Hashable, Identifiable {
        var remoteId: String
        var title: String
        var artists: [String]
        var album: String?
        var cover: String?
        var durationMs: Int?
        var track: Track?

        var id: String { remoteId }

        enum CodingKeys: String, CodingKey { case remoteId, title, artists, album, cover, durationMs, track }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            remoteId = try c.decode(String.self, forKey: .remoteId)
            title = c.opt(String.self, .title) ?? ""
            artists = (c.opt([String?].self, .artists) ?? []).compactMap { $0 }
            album = c.opt(String.self, .album)
            cover = c.opt(String.self, .cover)
            durationMs = c.opt(Int.self, .durationMs)
            track = c.opt(Track.self, .track)
        }
    }

    var artist: Info
    var albums: [Release]
    var top: [Top]
    var tracks: [Track]

    enum CodingKeys: String, CodingKey { case artist, albums, top, tracks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artist = try c.decode(Info.self, forKey: .artist)
        albums = c.opt(Lossy<Release>.self, .albums)?.items ?? []
        top = c.opt(Lossy<Top>.self, .top)?.items ?? []
        tracks = c.opt(Lossy<Track>.self, .tracks)?.items ?? []
    }
}

struct AlbumDetail: Decodable {
    struct Info: Decodable {
        var name: String?
        var artist: String?
        var cover: String?
        var releaseDate: String?
        var recordType: String?
        var unavailable: String?

        enum CodingKeys: String, CodingKey { case name, releaseName, artist, cover, releaseDate, recordType, unavailable }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.opt(String.self, .releaseName) ?? c.opt(String.self, .name)
            artist = c.opt(String.self, .artist)
            cover = c.opt(String.self, .cover)
            releaseDate = c.opt(String.self, .releaseDate)
            recordType = c.opt(String.self, .recordType)
            unavailable = c.opt(String.self, .unavailable)
        }
    }

    /// A song on the record: here (`track`) or only known of.
    struct Row: Decodable, Hashable, Identifiable {
        var pos: Int
        var title: String
        var artists: [String]
        var durationMs: Int?
        var track: Track?

        var id: Int { pos }

        enum CodingKeys: String, CodingKey { case pos, title, artists, durationMs, track }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pos = c.opt(Int.self, .pos) ?? 0
            title = c.opt(String.self, .title) ?? ""
            artists = (c.opt([String?].self, .artists) ?? []).compactMap { $0 }
            durationMs = c.opt(Int.self, .durationMs)
            track = c.opt(Track.self, .track)
        }
    }

    var album: Info
    var tracks: [Row]
    var extra: [Track]

    enum CodingKeys: String, CodingKey { case album, tracks, extra }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        album = try c.decode(Info.self, forKey: .album)
        tracks = c.opt(Lossy<Row>.self, .tracks)?.items ?? []
        extra = c.opt(Lossy<Track>.self, .extra)?.items ?? []
    }

    /// The songs that can be played, in the record's order.
    var playable: [Track] { tracks.compactMap { $0.track } + extra }
}

struct DeviceInfo: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String
    var platform: String?
    var kind: String?
    var isThis: Bool
    var live: Bool
    var playing: Bool
    var positionMs: Int
    var ageMs: Int
    var queue: String?
    var queueId: Int?
    var track: Track?

    enum CodingKeys: String, CodingKey {
        case id, name, platform, kind, live, playing, positionMs, ageMs, queue, queueId, track
        case isThis = "this"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.opt(String.self, .name) ?? "Device"
        platform = c.opt(String.self, .platform)
        kind = c.opt(String.self, .kind)
        isThis = c.opt(Bool.self, .isThis) ?? false
        live = c.opt(Bool.self, .live) ?? false
        playing = c.opt(Bool.self, .playing) ?? false
        positionMs = c.opt(Int.self, .positionMs) ?? 0
        ageMs = c.opt(Int.self, .ageMs) ?? 0
        queue = c.opt(String.self, .queue)
        queueId = c.opt(Int.self, .queueId)
        track = c.opt(Track.self, .track)
    }

    var icon: String {
        let n = name.lowercased()
        let p = (platform ?? "").lowercased()
        if n.contains("iphone") || p == "ios" { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if p.contains("android") || n.contains("android") || n.contains("phone") { return "candybarphone" }
        if p == "web" || n.contains("safari") || n.contains("firefox") || n.contains("chrome") { return "globe" }
        if n.contains("mac") { return "laptopcomputer" }
        return "desktopcomputer"
    }
}

struct DeviceList: Decodable {
    var this: Int?
    var devices: [DeviceInfo]

    enum CodingKeys: String, CodingKey { case this, devices }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        this = c.opt(Int.self, .this)
        devices = c.opt(Lossy<DeviceInfo>.self, .devices)?.items ?? []
    }
}

struct Holding: Decodable {
    var holding: [String: Int]
}

extension API {
    func lyrics(_ trackId: Int) async throws -> LyricsAnswer {
        try await get("/tracks/\(trackId)/lyrics")
    }

    func artist(_ name: String) async throws -> ArtistDetail {
        try await get("/library/artists/detail", query: ["artist": name])
    }

    func album(_ ref: AlbumRef) async throws -> AlbumDetail {
        var q: [String: String] = [:]
        if let r = ref.remoteId { q["remote_id"] = r }
        if let n = ref.name { q["album"] = n }
        if let a = ref.artist { q["artist"] = a }
        return try await get("/library/albums/detail", query: q)
    }

    func libraryArtists(offset: Int, q: String?) async throws -> Page<ArtistSummary> {
        var query = ["offset": String(offset), "limit": "200", "sort": "name"]
        if let q = q, !q.isEmpty { query["q"] = q }
        return try await get("/library/artists", query: query)
    }

    func libraryAlbums(offset: Int, q: String?, sort: String) async throws -> Page<AlbumSummary> {
        var query = ["offset": String(offset), "limit": "120", "sort": sort]
        if let q = q, !q.isEmpty { query["q"] = q }
        return try await get("/library/albums", query: query)
    }

    func librarySongs(offset: Int) async throws -> Page<Track> {
        try await get("/library/tracks", query: ["offset": String(offset), "limit": "200", "sort": "added"])
    }

    /// A playlist the house writes from a song, a record or an act.
    func startStation(kind: String, trackId: Int? = nil, artist: String? = nil, album: String? = nil) async throws -> Playlist {
        var body: [String: Any] = ["kind": kind]
        if let t = trackId { body["track_id"] = t }
        if let a = artist { body["artist"] = a }
        if let al = album { body["album"] = al }
        return try await send("POST", "/stations", json: body)
    }

    func extendStationPlaylist(_ stationId: Int) async throws {
        _ = try await data("POST", "/stations/\(stationId)/extend", json: ["count": 20])
    }

    func holding(_ trackIds: [Int]) async throws -> [Int: Int] {
        let h: Holding = try await send("POST", "/playlists/holding", json: ["track_ids": trackIds])
        var out: [Int: Int] = [:]
        for (k, v) in h.holding { if let id = Int(k) { out[id] = v } }
        return out
    }

    func addToPlaylist(_ id: Int, trackIds: [Int]) async throws {
        _ = try await data("POST", "/playlists/\(id)/items", json: ["track_ids": trackIds])
    }

    func removeFromPlaylist(_ id: Int, trackIds: [Int]) async throws -> Playlist {
        try await send("POST", "/playlists/\(id)/items/remove", json: ["track_ids": trackIds])
    }

    func createPlaylist(_ name: String) async throws -> Int {
        struct Made: Decodable { var id: Int }
        let m: Made = try await send("POST", "/playlists", json: ["name": name])
        return m.id
    }

    func renamePlaylist(_ id: Int, _ name: String) async throws -> Playlist {
        try await send("PATCH", "/playlists/\(id)", json: ["name": name])
    }

    func deletePlaylist(_ id: Int) async throws {
        _ = try await data("DELETE", "/playlists/\(id)")
    }

    func dislike(_ trackId: Int, undo: Bool = false) async throws {
        _ = try await data("POST", "/recommend/dislike", json: ["track_id": trackId, "undo": undo])
    }

    func devices() async throws -> DeviceList { try await get("/devices") }

    /// The queue's songs that are still to be fetched, ahead of every other download.
    func prioritise(_ queueId: Int) async throws {
        _ = try await data("POST", "/queues/\(queueId)/prioritise")
    }

    func reportState(playing: Bool, trackId: Int?, queueId: Int?, positionMs: Int, itemId: Int?) async throws {
        var body: [String: Any] = ["playing": playing, "position_ms": positionMs, "kind": "phone"]
        if let t = trackId { body["track_id"] = t }
        if let q = queueId { body["queue_id"] = q }
        if let i = itemId { body["item_id"] = i }
        _ = try await data("POST", "/devices/state", json: body, timeout: 10)
    }

    func command(_ deviceId: Int, _ action: String, queueId: Int? = nil, trackId: Int? = nil, positionMs: Int? = nil) async throws {
        var body: [String: Any] = ["action": action]
        if let q = queueId { body["queue_id"] = q }
        if let t = trackId { body["track_id"] = t }
        if let p = positionMs { body["position_ms"] = p }
        _ = try await data("POST", "/devices/\(deviceId)/command", json: body)
    }

    /// A song known only by name (an album row, an artist's top song) into the house.
    func resolve(title: String, artists: [String], album: String?, durationMs: Int?) async throws -> Track {
        var body: [String: Any] = ["query": ([title] + artists.prefix(1)).joined(separator: " "),
                                   "title": title, "artists": artists]
        if let a = album { body["album"] = a }
        if let d = durationMs { body["duration_ms"] = d }
        return try await send("POST", "/tracks/resolve", json: body)
    }

    /// A picture from another service (Deezer, YouTube), through the house.
    func remoteImage(_ url: String?) -> URL? {
        guard let u = url, !u.isEmpty else { return nil }
        return self.url("/art/remote", ["u": u])
    }
}

/// How a record is opened: by the library's spelling or by the release's id.
struct AlbumRef: Hashable {
    var name: String?
    var artist: String?
    var remoteId: String?
}
