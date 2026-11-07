import Foundation

// Listening together: somebody's queue opened to the others on the house. The host's
// device keeps time; everyone in the room sees what is on, adds to it and works the
// buttons (a guest's press is a request the host's player carries out).

struct JamMember: Decodable, Identifiable, Hashable {
    var userId: Int
    var name: String
    var host: Bool
    var online: Bool

    var id: Int { userId }

    enum CodingKeys: String, CodingKey { case userId, name, host, online }

    init(userId: Int, name: String, host: Bool = false, online: Bool = true) {
        self.userId = userId
        self.name = name
        self.host = host
        self.online = online
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(Int.self, forKey: .userId)
        name = c.opt(String.self, .name) ?? "Someone"
        host = c.opt(Bool.self, .host) ?? false
        online = c.opt(Bool.self, .online) ?? false
    }
}

/// What the host's player is doing, and how old that news is.
struct JamPlayback: Decodable, Equatable {
    var trackId: Int?
    /// Which row: a queue can hold a song twice.
    var itemId: Int?
    var positionMs: Int
    var playing: Bool
    var ageMs: Int
    /// The host's own count of what it has said; a lower one was overtaken on the way.
    var seq: Int?

    enum CodingKeys: String, CodingKey { case trackId, itemId, positionMs, playing, ageMs, seq }

    init(trackId: Int?, itemId: Int? = nil, positionMs: Int, playing: Bool, ageMs: Int = 0, seq: Int? = nil) {
        self.trackId = trackId
        self.itemId = itemId
        self.positionMs = positionMs
        self.playing = playing
        self.ageMs = ageMs
        self.seq = seq
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackId = c.opt(Int.self, .trackId)
        itemId = c.opt(Int.self, .itemId)
        positionMs = c.opt(Int.self, .positionMs) ?? 0
        playing = c.opt(Bool.self, .playing) ?? false
        ageMs = c.opt(Int.self, .ageMs) ?? 0
        seq = c.opt(Int.self, .seq)
    }

    /// From a live event's body (no age: it is news as it arrives).
    init?(event obj: [String: Any]) {
        func int(_ k: String) -> Int? { (obj[k] as? NSNumber)?.intValue }
        guard obj["playing"] != nil || obj["track_id"] != nil else { return nil }
        self.init(trackId: int("track_id"), itemId: int("item_id"), positionMs: int("position_ms") ?? 0,
                  playing: (obj["playing"] as? Bool) ?? ((obj["playing"] as? NSNumber)?.boolValue ?? false),
                  ageMs: int("age_ms") ?? 0, seq: int("seq"))
    }

    /// Where the room is, in seconds, as of the moment this was heard.
    var seconds: Double { Double(positionMs + (playing ? ageMs : 0)) / 1000 }
}

struct Jam: Decodable, Equatable {
    var id: Int
    var code: String
    var queueId: Int
    var host: String?
    var isHost: Bool
    var members: [JamMember]
    var listening: Int
    var nowPlaying: Track?
    var playback: JamPlayback?

    enum CodingKeys: String, CodingKey { case id, code, queueId, host, isHost, members, listening, nowPlaying, playback }

    init(id: Int, code: String, queueId: Int, host: String?, isHost: Bool, members: [JamMember],
         listening: Int, nowPlaying: Track? = nil, playback: JamPlayback? = nil) {
        self.id = id
        self.code = code
        self.queueId = queueId
        self.host = host
        self.isHost = isHost
        self.members = members
        self.listening = listening
        self.nowPlaying = nowPlaying
        self.playback = playback
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        code = c.opt(String.self, .code) ?? ""
        queueId = c.opt(Int.self, .queueId) ?? 0
        host = c.opt(String.self, .host)
        isHost = c.opt(Bool.self, .isHost) ?? false
        members = c.opt(Lossy<JamMember>.self, .members)?.items ?? []
        listening = c.opt(Int.self, .listening) ?? members.filter { $0.online }.count
        nowPlaying = c.opt(Track.self, .nowPlaying)
        playback = c.opt(JamPlayback.self, .playback)
    }

    var hostName: String { host ?? "Someone" }
    var title: String { isHost ? "Your jam" : "\(hostName)'s jam" }

    /// "3 listening", or who else is here when it is two of you.
    var crowd: String {
        let n = max(listening, 1)
        return n == 1 ? "Just you so far" : "\(n) listening"
    }
}

/// A jam running on the house, from the list of rooms with the lights on.
struct RunningJam: Decodable, Identifiable, Hashable {
    var id: Int
    var code: String
    var queueId: Int
    var host: String
    var queue: String?
    var listening: Int
    var playing: String?
    var by: String?
    var joined: Bool

    enum CodingKeys: String, CodingKey { case id, code, queueId, host, queue, listening, playing, by, joined }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        code = c.opt(String.self, .code) ?? ""
        queueId = c.opt(Int.self, .queueId) ?? 0
        host = c.opt(String.self, .host) ?? "Someone"
        queue = c.opt(String.self, .queue)
        listening = c.opt(Int.self, .listening) ?? 0
        playing = c.opt(String.self, .playing)
        by = c.opt(String.self, .by)
        joined = c.opt(Bool.self, .joined) ?? false
    }

    var nowLine: String? {
        guard let p = playing else { return nil }
        return by.map { "\(p) · \($0)" } ?? p
    }
}

/// Somebody with an account on the house.
struct Person: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var online: Bool

    enum CodingKeys: String, CodingKey { case id, name, online }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.opt(String.self, .name) ?? "Someone"
        online = c.opt(Bool.self, .online) ?? false
    }
}

private struct JamAnswer: Decodable {
    var jam: Jam?

    enum CodingKeys: String, CodingKey { case jam }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jam = c.opt(Jam.self, .jam)
    }
}

/// The arithmetic of keeping in step, apart from the player so it can be tested.
enum RoomClock {
    /// Where the room has got to [since] seconds after it said [position].
    static func carried(_ position: Double, playing: Bool, since: Double, length: Double?) -> Double {
        // A paused room is paused somewhere and stays there; news over two minutes old
        // is not carried forward at all.
        guard playing, since > 0, since < 120 else { return position }
        let now = position + since
        if let l = length, l > 0 { return min(now, l) }
        return now
    }

    /// True when [seq] is older than what has been heard already.
    static func isStale(_ seq: Int?, heard: Int?) -> Bool {
        guard let s = seq, let h = heard else { return false }
        return s < h
    }

    /// Where a row a guest picked goes so that it is next: straight after the one
    /// playing, counted the house's way (with the row lifted out).
    static func nextSlot(for row: Int, playing: Int) -> Int {
        row < playing ? playing : playing + 1
    }

    /// The phone has gone on to the next song a moment before the host: not worth
    /// going back for the last bars of the old one.
    static func justAhead(hostOn previousLength: Double, hostAt: Double, hereAt: Double) -> Bool {
        previousLength > 0 && previousLength - hostAt < 8 && hereAt < 8
    }

    /// The host's report counter: milliseconds since 1970, always going up.
    static func nextSeq(after last: Int, now: Date = Date()) -> Int {
        let stamp = Int(now.timeIntervalSince1970 * 1000)
        return stamp > last ? stamp : last + 1
    }
}

extension API {
    func currentJam() async throws -> Jam? {
        let a: JamAnswer = try await get("/jams/current")
        return a.jam
    }

    func startJam(queueId: Int) async throws -> Jam {
        try await send("POST", "/jams", json: ["queue_id": queueId])
    }

    func joinJam(code: String) async throws -> Jam {
        try await send("POST", "/jams/join", json: ["code": code])
    }

    func runningJams() async throws -> [RunningJam] {
        let p: Page<RunningJam> = try await get("/jams")
        return p.items
    }

    func jamPeople() async throws -> [Person] {
        let p: Page<Person> = try await get("/jams/people")
        return p.items
    }

    func inviteToJam(_ id: Int, userId: Int) async throws -> Jam {
        try await send("POST", "/jams/\(id)/invite", json: ["user_id": userId])
    }

    func leaveJam(_ id: Int) async throws {
        _ = try await data("POST", "/jams/\(id)/leave")
    }

    func removeFromJam(_ id: Int, userId: Int) async throws {
        _ = try await data("POST", "/jams/\(id)/remove", json: ["user_id": userId])
    }

    func pushJamPlayback(_ id: Int, trackId: Int?, itemId: Int?, positionMs: Int, playing: Bool, seq: Int) async throws {
        var body: [String: Any] = ["position_ms": positionMs, "playing": playing, "seq": seq]
        if let t = trackId { body["track_id"] = t }
        if let i = itemId { body["item_id"] = i }
        _ = try await data("POST", "/jams/\(id)/playback", json: body, timeout: 10)
    }

    func moveJam(_ id: Int, queueId: Int) async throws -> Jam {
        try await send("POST", "/jams/\(id)/queue", json: ["queue_id": queueId])
    }

    func jamControl(_ id: Int, _ action: String, positionMs: Int? = nil, trackId: Int? = nil) async throws {
        var body: [String: Any] = ["action": action]
        if let p = positionMs { body["position_ms"] = p }
        if let t = trackId { body["track_id"] = t }
        _ = try await data("POST", "/jams/\(id)/control", json: body, timeout: 10)
    }
}
