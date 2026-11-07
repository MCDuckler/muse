import Foundation

// The house's JSON, as the phone needs it. Decoded with convertFromSnakeCase, so
// `cover_url` arrives as `coverUrl`. Almost everything is optional: one odd row must
// never cost a whole list, and lists decode through `Lossy`, which drops the row
// that does not fit instead of failing.

extension KeyedDecodingContainer {
    /// The value under [key] if it is there and of the right type, else nil.
    func opt<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard let v = try? decodeIfPresent(type, forKey: key) else { return nil }
        return v
    }
}

/// A list that keeps every element that decodes and skips the rest.
struct Lossy<Element: Decodable>: Decodable {
    var items: [Element]

    init(_ items: [Element]) { self.items = items }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        if let n = c.count { out.reserveCapacity(n) }
        while !c.isAtEnd {
            if let v = try? c.decode(Element.self) {
                out.append(v)
            } else {
                // A failed decode does not move the container on; this does.
                _ = try? c.decode(Skip.self)
            }
        }
        items = out
    }

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// A song. Rows in a queue also carry their own row id and position.
struct Track: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    var displayTitle: String?
    var artists: [String]
    var album: String?
    var durationMs: Int?
    var state: String
    var coverUrl: String?
    var coverColor: String?
    var coverVersion: String?
    var streamUrl: String?
    var gainDb: Double?
    var bytes: Int?
    var failReason: String?
    // In a queue
    var pos: Int?
    var itemId: Int?
    var origin: String?
    // In the history
    var lastPlayed: String?

    enum CodingKeys: String, CodingKey {
        case id, title, displayTitle, artists, album, durationMs, state, coverUrl, coverColor,
             coverVersion, streamUrl, gainDb, bytes, failReason, pos, itemId, origin, lastPlayed
    }

    init(id: Int, title: String, artists: [String], album: String? = nil, durationMs: Int? = nil,
         state: String = "ready", coverUrl: String? = nil, coverColor: String? = nil,
         streamUrl: String? = nil) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMs = durationMs
        self.state = state
        self.coverUrl = coverUrl
        self.coverColor = coverColor
        self.streamUrl = streamUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = c.opt(String.self, .title) ?? "Untitled"
        displayTitle = c.opt(String.self, .displayTitle)
        artists = c.opt([String].self, .artists) ?? []
        album = c.opt(String.self, .album)
        durationMs = c.opt(Int.self, .durationMs)
        state = c.opt(String.self, .state) ?? "pending"
        coverUrl = c.opt(String.self, .coverUrl)
        coverColor = c.opt(String.self, .coverColor)
        coverVersion = c.opt(String.self, .coverVersion)
        streamUrl = c.opt(String.self, .streamUrl)
        gainDb = c.opt(Double.self, .gainDb)
        bytes = c.opt(Int.self, .bytes)
        failReason = c.opt(String.self, .failReason)
        pos = c.opt(Int.self, .pos)
        itemId = c.opt(Int.self, .itemId)
        origin = c.opt(String.self, .origin)
        lastPlayed = c.opt(String.self, .lastPlayed)
    }

    /// The title without the artist's name or "(Official Video)" glued onto it.
    var name: String {
        if let d = displayTitle, !d.isEmpty { return d }
        return title
    }

    var artistLine: String { artists.isEmpty ? "Unknown artist" : artists.joined(separator: ", ") }

    /// The house has the audio.
    var isReady: Bool { streamUrl != nil }

    var isFailed: Bool { state == "failed" }

    var seconds: Double { Double(durationMs ?? 0) / 1000 }

    /// What identifies this row in a list that may hold the same song twice.
    var rowKey: String { itemId.map { "i\($0)" } ?? "t\(id)" }
}

struct StationRef: Codable, Hashable {
    var id: Int?
    var kind: String?
    var playlistId: Int?
}

/// A playlist. The list of playlists sends `items` as a count; one playlist sends the
/// songs themselves.
struct Playlist: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var kind: String
    var count: Int
    var tracks: [Track]?
    var coverUrl: String?
    var coverVersion: String?
    var pinned: Bool
    var saved: Bool
    var ownerName: String?
    var waiting: Int
    var station: StationRef?
    var lastOpenedAt: String?
    var editable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, items, coverUrl, coverVersion, pinned, saved, ownerName, waiting, station, lastOpenedAt, editable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.opt(String.self, .name) ?? ""
        kind = c.opt(String.self, .kind) ?? "local"
        if let n = try? c.decode(Int.self, forKey: .items) {
            count = n
            tracks = nil
        } else if let list = try? c.decode(Lossy<Track>.self, forKey: .items) {
            tracks = list.items
            count = list.items.count
        } else {
            count = 0
            tracks = nil
        }
        coverUrl = c.opt(String.self, .coverUrl)
        coverVersion = c.opt(String.self, .coverVersion)
        pinned = c.opt(Bool.self, .pinned) ?? false
        saved = c.opt(Bool.self, .saved) ?? false
        ownerName = c.opt(String.self, .ownerName)
        waiting = c.opt(Int.self, .waiting) ?? 0
        station = c.opt(StationRef.self, .station)
        lastOpenedAt = c.opt(String.self, .lastOpenedAt)
        editable = c.opt(Bool.self, .editable)
    }

    var isFavourites: Bool { kind == "favourites" }

    /// Songs can be put on it and taken off it here.
    var canEdit: Bool { editable ?? (!saved && (kind == "local" || kind == "favourites" || kind == "station")) }

    var shownName: String { isFavourites ? "Favourites" : name }

    var totalSeconds: Double { (tracks ?? []).reduce(0) { $0 + $1.seconds } }
    var isStation: Bool { kind == "station" }

    var subtitle: String {
        var parts = ["\(count) song\(count == 1 ? "" : "s")"]
        if isStation { parts.append("station") }
        if let o = ownerName, saved { parts.append(o) }
        return parts.joined(separator: " · ")
    }
}

enum RepeatMode: String, Codable {
    case off, one, all

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// A queue: its own order, cursor and repeat. One sent alone carries a window of its
/// rows (`windowFrom` onwards); the list of queues sends `items` as a count.
struct QueueState: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var cursorIndex: Int
    var positionMs: Int
    var rev: Int
    var repeatMode: RepeatMode
    var total: Int
    var windowFrom: Int
    var items: [Track]
    var station: StationRef?
    var sharedFrom: String?

    enum CodingKeys: String, CodingKey {
        case id, name, cursorIndex, positionMs, rev, items, total, windowFrom, station, sharedFrom
        case repeatMode = "repeat"
    }

    init(id: Int, name: String, items: [Track], cursorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.cursorIndex = cursorIndex
        self.positionMs = 0
        self.rev = 1
        self.repeatMode = .off
        self.total = items.count
        self.windowFrom = 0
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.opt(String.self, .name) ?? "Queue"
        cursorIndex = c.opt(Int.self, .cursorIndex) ?? 0
        positionMs = c.opt(Int.self, .positionMs) ?? 0
        rev = c.opt(Int.self, .rev) ?? 1
        let r = c.opt(String.self, .repeatMode) ?? "off"
        repeatMode = RepeatMode(rawValue: r) ?? .off
        windowFrom = c.opt(Int.self, .windowFrom) ?? 0
        if let list = try? c.decode(Lossy<Track>.self, forKey: .items) {
            items = list.items
            total = c.opt(Int.self, .total) ?? list.items.count
        } else {
            items = []
            let n = (try? c.decode(Int.self, forKey: .items)) ?? 0
            total = c.opt(Int.self, .total) ?? n
        }
        station = c.opt(StationRef.self, .station)
        sharedFrom = c.opt(String.self, .sharedFrom)
    }

    /// The row at an index into the whole queue, if this window holds it.
    func track(at index: Int) -> Track? {
        let i = index - windowFrom
        return items.indices.contains(i) ? items[i] : nil
    }

    /// The whole-queue index of a row, by its row id.
    func index(ofItem itemId: Int) -> Int? {
        items.firstIndex { $0.itemId == itemId }.map { $0 + windowFrom }
    }

    /// Holds only part of a long queue.
    var isWindowed: Bool { total > items.count }

    var isStation: Bool { station?.id != nil }
}

struct RemoteHit: Decodable, Hashable, Identifiable {
    var videoId: String
    var title: String
    var artists: [String]
    var album: String?
    var durationMs: Int?
    var known: Bool
    var coverUrl: String?

    var id: String { videoId }

    enum CodingKeys: String, CodingKey { case videoId, title, artists, album, durationMs, known, coverUrl }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = c.opt(String.self, .title) ?? ""
        artists = c.opt([String].self, .artists) ?? []
        album = c.opt(String.self, .album)
        durationMs = c.opt(Int.self, .durationMs)
        known = c.opt(Bool.self, .known) ?? false
        coverUrl = c.opt(String.self, .coverUrl)
    }

    var artistLine: String { artists.isEmpty ? "Unknown artist" : artists.joined(separator: ", ") }
}

struct SearchResults: Decodable {
    var local: [Track]
    var remote: [RemoteHit]
    var remoteError: String?

    enum CodingKeys: String, CodingKey { case local, remote, remoteError }

    init(local: [Track] = [], remote: [RemoteHit] = [], remoteError: String? = nil) {
        self.local = local
        self.remote = remote
        self.remoteError = remoteError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        local = c.opt(Lossy<Track>.self, .local)?.items ?? []
        remote = c.opt(Lossy<RemoteHit>.self, .remote)?.items ?? []
        remoteError = c.opt(String.self, .remoteError)
    }
}

/// One song offered on the home page: in the library (`track`) or not yet (`hit`).
struct Pick: Decodable, Hashable, Identifiable {
    var place: String
    var why: String
    var track: Track?
    var hit: RemoteHit?

    enum CodingKeys: String, CodingKey {
        case why, track, hit
        case place = "where"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        place = c.opt(String.self, .place) ?? "library"
        why = c.opt(String.self, .why) ?? ""
        track = c.opt(Track.self, .track)
        hit = c.opt(RemoteHit.self, .hit)
        if track == nil && hit == nil {
            throw DecodingError.dataCorruptedError(forKey: .track, in: c, debugDescription: "empty pick")
        }
    }

    var id: String { track.map { "t\($0.id)" } ?? "v\(hit?.videoId ?? "")" }
    var title: String { track?.name ?? hit?.title ?? "" }
    var artistLine: String { track?.artistLine ?? hit?.artistLine ?? "" }
}

struct PickSection: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    var items: [Pick]

    enum CodingKeys: String, CodingKey { case id, name, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.opt(String.self, .name) ?? ""
        items = c.opt(Lossy<Pick>.self, .items)?.items ?? []
    }
}

struct HomePicks: Decodable {
    var sections: [PickSection]

    enum CodingKeys: String, CodingKey { case sections }

    init(sections: [PickSection] = []) { self.sections = sections }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = c.opt(Lossy<PickSection>.self, .sections)?.items ?? []
    }
}

struct Me: Decodable {
    var user: String
    var userId: Int?
    var score: Int?
}

struct StreamKey: Decodable {
    var key: String
    var expiresAt: Double
}

struct Favourites: Decodable {
    var playlistId: Int?
    var trackIds: [Int]
}

struct LoginAnswer: Decodable {
    var token: String
    var user: String
}

struct FavouriteAnswer: Decodable {
    var favourite: Bool
}

// MARK: Local edits to a queue window, made at once and then confirmed by the house.

extension QueueState {
    /// Rows inserted at a whole-queue index (clamped into the window).
    mutating func insert(_ tracks: [Track], at index: Int) {
        let i = max(0, min(index - windowFrom, items.count))
        items.insert(contentsOf: tracks, at: i)
        total += tracks.count
    }

    mutating func remove(at index: Int) {
        let i = index - windowFrom
        guard items.indices.contains(i) else { return }
        items.remove(at: i)
        total -= 1
        if cursorIndex > index { cursorIndex -= 1 }
    }

    /// Move one row, `to` counted with the row already lifted out (as a drag does).
    mutating func move(from: Int, to: Int) {
        let f = from - windowFrom
        guard items.indices.contains(f) else { return }
        let row = items.remove(at: f)
        let t = max(0, min(to - windowFrom, items.count))
        items.insert(row, at: t)
    }

    /// The whole-queue index of the copy of [trackId] nearest to [around].
    func nearest(trackId: Int, around: Int) -> Int? {
        var best: Int?
        for (i, t) in items.enumerated() where t.id == trackId {
            let abs = i + windowFrom
            if best == nil || Swift.abs(abs - around) < Swift.abs(best! - around) { best = abs }
        }
        return best
    }

    var lastIndex: Int { windowFrom + items.count - 1 }
}
