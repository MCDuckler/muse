import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? { message }

    /// No answer at all: no signal, the box down, a timeout.
    var isOffline: Bool { status == 0 }

    static func from(_ error: Error) -> APIError {
        if let e = error as? APIError { return e }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return APIError(status: 0, message: "No connection")
            case .timedOut:
                return APIError(status: 0, message: "The house took too long to answer")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return APIError(status: 0, message: "Can't reach the house")
            case .cancelled:
                return APIError(status: -2, message: "Cancelled")
            default:
                return APIError(status: 0, message: u.localizedDescription)
            }
        }
        return APIError(status: -1, message: error.localizedDescription)
    }
}

/// Where requests go. The live one is URLSession; demo mode answers from fixtures.
protocol Transport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct LiveTransport: Transport {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 180
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: 0, message: "No answer")
        }
        return (data, http)
    }
}

/// Talks to one WetOwl house. Thread-safe: the token and the stream key sit behind a
/// lock, everything else is fixed.
final class API: @unchecked Sendable {
    static let defaultServer = "https://89-58-49-140.nip.io"

    let transport: Transport
    private let lock = NSLock()
    private var _base: String
    private var _token: String?
    private var _streamKey: String?
    private var _streamKeyExpiry: Double = 0
    private var _onUnauthorized: (() -> Void)?

    init(base: String, token: String?, transport: Transport) {
        _base = API.normalise(base)
        _token = token
        self.transport = transport
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    var base: String {
        get { locked { _base } }
        set { let v = API.normalise(newValue); locked { _base = v } }
    }

    var token: String? {
        get { locked { _token } }
        set { locked { _token = newValue } }
    }

    var onUnauthorized: (() -> Void)? {
        get { locked { _onUnauthorized } }
        set { locked { _onUnauthorized = newValue } }
    }

    static func normalise(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return defaultServer }
        if !v.hasPrefix("http://") && !v.hasPrefix("https://") { v = "https://" + v }
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }

    // MARK: URLs

    func url(_ path: String, _ query: [String: String] = [:]) -> URL? {
        guard var c = URLComponents(string: base + path) else { return nil }
        if !query.isEmpty {
            var items = c.queryItems ?? []
            for (k, v) in query.sorted(by: { $0.key < $1.key }) {
                items.append(URLQueryItem(name: k, value: v))
            }
            c.queryItems = items
        }
        return c.url
    }

    /// A request carrying the token, for anything fetched from the house.
    func authorized(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        if let t = token { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }

    func coverURL(_ t: Track, small: Bool) -> URL? {
        guard let p = t.coverUrl else { return nil }
        var q = ["size": small ? "sm" : "lg"]
        if let v = t.coverVersion { q["v"] = v }
        return url(p, q)
    }

    func coverURL(_ p: Playlist) -> URL? {
        guard let path = p.coverUrl else { return nil }
        return url(path, p.coverVersion.map { ["v": $0] } ?? [:])
    }

    func coverURL(_ h: RemoteHit) -> URL? {
        guard let p = h.coverUrl else { return nil }
        // Already carries its own query (/art/remote?u=…).
        return URL(string: base + p)
    }

    /// The audio, with the signed key AVPlayer needs (it cannot be given a header).
    func streamURL(_ t: Track) -> URL? {
        guard let p = t.streamUrl else { return nil }
        let key = locked { _streamKey }
        return url(p, key.map { ["k": $0] } ?? [:])
    }

    var hasFreshStreamKey: Bool {
        locked { _streamKey != nil && _streamKeyExpiry - 3600 > Date().timeIntervalSince1970 }
    }

    // MARK: Requests

    func data(_ method: String = "GET", _ path: String, query: [String: String] = [:],
              json: Any? = nil, form: [String: String]? = nil,
              timeout: TimeInterval? = nil) async throws -> Data {
        guard let u = url(path, query) else { throw APIError(status: -1, message: "Bad address") }
        var r = authorized(u)
        r.httpMethod = method
        if let t = timeout { r.timeoutInterval = t }
        if let json = json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let form = form {
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = API.formBody(form).data(using: .utf8)
        }
        let answer: (Data, HTTPURLResponse)
        do {
            answer = try await transport.send(r)
        } catch {
            throw APIError.from(error)
        }
        let (d, res) = answer
        if res.statusCode == 401 && path != "/auth/login" {
            onUnauthorized?()
            throw APIError(status: 401, message: "Signed out. Sign in again.")
        }
        if res.statusCode >= 400 {
            throw APIError(status: res.statusCode, message: API.detail(d, res.statusCode))
        }
        return d
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try API.decode(try await data("GET", path, query: query))
    }

    /// The decoded answer and its bytes (for the disk cache). Not actor-bound, so the
    /// decoding runs off the main thread.
    func fetch<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> (T, Data) {
        let d = try await data("GET", path, query: query)
        return (try API.decode(d), d)
    }

    func send<T: Decodable>(_ method: String, _ path: String, json: Any? = nil) async throws -> T {
        try API.decode(try await data(method, path, json: json))
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try d.decode(T.self, from: data)
        } catch {
            Log.shared.add("decode \(T.self) failed: \(error)")
            throw APIError(status: -1, message: "The house answered in a way this app does not understand")
        }
    }

    static func encode<T: Encodable>(_ v: T) -> Data? {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return try? e.encode(v)
    }

    static func formBody(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    static func detail(_ data: Data, _ status: Int) -> String {
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = o["detail"] as? String { return s }
            if let list = o["detail"] as? [[String: Any]] {
                let msgs = list.compactMap { $0["msg"] as? String }
                if !msgs.isEmpty { return msgs.joined(separator: ". ") }
            }
            if let d = o["detail"] as? [String: Any], let r = d["reason"] as? String { return r }
        }
        if let s = String(data: data, encoding: .utf8), s.hasPrefix("<") {
            return "The house answered with a web page (\(status))"
        }
        return "Request failed (\(status))"
    }

    // MARK: Endpoints

    func login(user: String, password: String, device: String) async throws -> LoginAnswer {
        let d = try await data("POST", "/auth/login",
                               form: ["user": user, "password": password, "device": device,
                                      "platform": "ios"])
        let a: LoginAnswer = try API.decode(d)
        token = a.token
        return a
    }

    func me() async throws -> Me { try await get("/me") }

    func refreshStreamKey() async throws {
        let k: StreamKey = try await get("/auth/stream-key")
        locked {
            _streamKey = k.key
            _streamKeyExpiry = k.expiresAt
        }
    }

    func track(_ id: Int) async throws -> Track { try await get("/tracks/\(id)") }

    func queue(_ id: Int, around: Int? = nil) async throws -> QueueState {
        try await get("/queues/\(id)", query: around.map { ["around": String($0)] } ?? [:])
    }

    func queues() async throws -> [QueueState] {
        let l: Lossy<QueueState> = try await get("/queues")
        return l.items
    }

    func createQueue(_ name: String, stationId: Int? = nil) async throws -> QueueState {
        var body: [String: Any] = ["name": name]
        if let s = stationId { body["station_id"] = s }
        return try await send("POST", "/queues", json: body)
    }

    func replaceQueue(_ id: Int, rev: Int, trackIds: [Int], cursor: Int) async throws -> QueueState {
        try await send("PUT", "/queues/\(id)", json: ["rev": rev, "items": trackIds, "cursor_index": cursor])
    }

    func addToQueue(_ id: Int, trackIds: [Int], next: Bool) async throws -> QueueState {
        try await send("POST", "/queues/\(id)/items", json: ["track_ids": trackIds, "mode": next ? "next" : "end"])
    }

    func moveInQueue(_ id: Int, from: Int, to: Int) async throws -> QueueState {
        try await send("POST", "/queues/\(id)/move", json: ["from": from, "to": to])
    }

    func removeFromQueue(_ id: Int, at pos: Int) async throws -> QueueState {
        try await send("DELETE", "/queues/\(id)/items/\(pos)")
    }

    func shuffleQueue(_ id: Int) async throws -> QueueState {
        try await send("POST", "/queues/\(id)/shuffle", json: [String: Any]())
    }

    func setRepeat(_ id: Int, _ mode: RepeatMode) async throws -> QueueState {
        try await send("PATCH", "/queues/\(id)", json: ["repeat": mode.rawValue])
    }

    func setCursor(_ id: Int, index: Int, positionMs: Int) async throws {
        _ = try await data("PATCH", "/queues/\(id)/cursor",
                           json: ["cursor_index": index, "position_ms": positionMs], timeout: 10)
    }

    /// More songs on the end of a station's queue.
    func extendStation(_ stationId: Int, queueId: Int) async throws -> QueueState? {
        let d = try await data("POST", "/stations/\(stationId)/extend",
                               json: ["queue_id": queueId, "count": 20])
        struct Answer: Decodable { var queue: QueueState? }
        let a: Answer = try API.decode(d)
        return a.queue
    }

    func search(_ q: String) async throws -> SearchResults {
        try await get("/search", query: ["q": q, "limit": "20"])
    }

    /// A YouTube Music hit into the house: answered at once when it is there already,
    /// else queued for fetching (state pending).
    func resolve(_ h: RemoteHit) async throws -> Track {
        var body: [String: Any] = ["video_id": h.videoId, "title": h.title, "artists": h.artists]
        if let a = h.album { body["album"] = a }
        if let ms = h.durationMs { body["duration_ms"] = ms }
        return try await send("POST", "/tracks/resolve", json: body)
    }

    func favourites() async throws -> Favourites { try await get("/favourites") }

    func setFavourite(_ trackId: Int, _ on: Bool) async throws -> Bool {
        let a: FavouriteAnswer = try await send("POST", "/favourites/\(trackId)", json: ["favourite": on])
        return a.favourite
    }

    func listen(trackId: Int, ms: Int, completed: Bool) async throws {
        _ = try await data("POST", "/listens", json: ["track_id": trackId, "ms_played": ms, "completed": completed])
    }

    func sendLog(lines: [String], device: String, build: String) async throws {
        _ = try await data("POST", "/playback-log", json: ["lines": lines, "device": device, "build": build])
    }
}
