import Foundation
import UIKit

/// A house in the app, for screenshots: launched with `-demo 1 -screen <name>`.
/// Answers every request from fixtures; covers are drawn. Nothing leaves the phone.
struct DemoTransport: Transport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw APIError(status: -1, message: "no url") }
        let path = url.path
        let method = request.httpMethod ?? "GET"
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ k: String) -> String? { q.first { $0.name == k }?.value }

        if path.hasSuffix("/cover") || path == "/art/remote" {
            let seed = path.split(separator: "/").compactMap { Int($0) }.first ?? (param("u")?.count ?? 7)
            return (DemoData.cover(seed: seed), ok(url, "image/png"))
        }
        let body: Any
        switch (method, path) {
        case ("GET", "/me"):
            body = ["user": "chris", "user_id": 1, "score": 1873] as [String: Any]
        case ("GET", "/auth/stream-key"):
            body = ["key": "demo", "expires_at": 4_000_000_000] as [String: Any]
        case ("GET", "/playlists"):
            body = DemoData.playlists.map { $0.summary }
        case ("GET", _) where path.hasPrefix("/playlists/"):
            let id = Int(path.split(separator: "/").last ?? "") ?? 1
            body = DemoData.playlist(id)
        case ("GET", "/queues"):
            body = DemoData.queues
        case ("GET", _) where path.hasPrefix("/queues/"):
            body = DemoData.queue
        case ("GET", "/recommend/home"):
            body = DemoData.home
        case ("GET", "/history"):
            body = Array(DemoData.tracks.shuffledStable().prefix(12))
        case ("GET", "/favourites"):
            body = ["playlist_id": 1, "track_ids": [3, 5, 8, 13, 21]] as [String: Any]
        case ("GET", "/search"):
            body = DemoData.search(param("q") ?? "")
        case (_, _) where path.hasPrefix("/queues/"):
            body = DemoData.queue
        case ("POST", _) where path.hasPrefix("/favourites/"):
            body = ["favourite": true] as [String: Any]
        default:
            body = [String: Any]()
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        return (data, ok(url, "application/json"))
    }

    private func ok(_ url: URL, _ type: String) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
    }
}

enum DemoData {
    static let colours = ["#c0392b", "#2e86de", "#16a085", "#8e44ad", "#d35400", "#27ae60", "#f39c12",
                          "#2c3e50", "#e84393", "#00b894", "#6c5ce7", "#fdcb6e", "#e17055", "#0984e3"]

    static let songs: [(String, String, Int)] = [
        ("Glass Harbour", "Mira Holt", 241), ("Nightbus to Ostend", "The Low Arches", 318),
        ("Velvet Static", "Kanto Sun", 205), ("Paper Moons", "Ida Brenner", 262),
        ("Lowlands", "Felt Engine", 287), ("Signal Fire", "Oskar & The Tide", 233),
        ("Hollow Bloom", "Mira Holt", 199), ("Concrete Garden", "Junebug Radio", 276),
        ("Late Light", "Saltwater Choir", 352), ("Telegraph Hill", "The Low Arches", 224),
        ("Copper Sky", "Nadia Vale", 247), ("After the Rain Machine", "Kanto Sun", 301),
        ("Slow Comet", "Ida Brenner", 268), ("Northbound", "Felt Engine", 213),
        ("Wild Geometry", "Junebug Radio", 239), ("Afterglow Dept.", "Saltwater Choir", 295),
        ("Small Hours", "Nadia Vale", 221), ("Satellite Hearts", "Oskar & The Tide", 254),
        ("Undertow", "Mira Holt", 280), ("Fieldnotes", "Kanto Sun", 192),
        ("Echo Park Avenue", "The Low Arches", 266), ("Morning Freight", "Felt Engine", 310),
        ("Bright Water", "Ida Brenner", 230), ("Static Bloom", "Junebug Radio", 244),
    ]

    static let tracks: [[String: Any]] = (0..<songs.count).map { makeTrack($0) }

    static func makeTrack(_ i: Int) -> [String: Any] {
        let (title, artist, seconds) = songs[i]
        var d: [String: Any] = [:]
        d["id"] = i + 1
        d["title"] = title
        d["display_title"] = title
        d["artists"] = [artist]
        d["album"] = "Demo Record \(i % 5 + 1)"
        d["duration_ms"] = seconds * 1000
        d["state"] = "ready"
        d["cover_url"] = "/tracks/\(i + 1)/cover"
        d["cover_color"] = colours[i % colours.count]
        d["cover_version"] = "d\(i)"
        d["stream_url"] = "/tracks/\(i + 1)/stream"
        d["gain_db"] = -3.2
        d["bytes"] = seconds * 16_000
        return d
    }

    struct List {
        let id: Int
        let name: String
        let kind: String
        let range: Range<Int>
        var summary: [String: Any] {
            let d: [String: Any] = ["id": id, "name": name, "kind": kind, "items": range.count, "cover_url": "/playlists/\(id)/cover",
             "cover_version": "p\(id)", "pinned": id == 2, "saved": false, "waiting": 0]
            return d
        }
    }

    static let playlists: [List] = [
        List(id: 1, name: "Favourites", kind: "favourites", range: 0..<18),
        List(id: 2, name: "Late night drives", kind: "local", range: 2..<20),
        List(id: 3, name: "Sunday slow", kind: "local", range: 5..<15),
        List(id: 4, name: "Station: Mira Holt", kind: "station", range: 0..<24),
        List(id: 5, name: "Running 170", kind: "local", range: 8..<22),
        List(id: 6, name: "Kitchen disco", kind: "local", range: 1..<12),
        List(id: 7, name: "Bandcamp Fridays", kind: "local", range: 10..<24),
    ]

    static func playlist(_ id: Int) -> [String: Any] {
        let l = playlists.first { $0.id == id } ?? playlists[1]
        var d = l.summary
        d["items"] = l.range.enumerated().map { pos, i -> [String: Any] in
            var t = tracks[i]
            t["pos"] = pos
            return t
        }
        return d
    }

    static var queueItems: [[String: Any]] {
        (2..<20).enumerated().map { pos, i -> [String: Any] in
            var t = tracks[i]
            t["pos"] = pos
            t["item_id"] = 1000 + pos
            t["origin"] = "user"
            return t
        }
    }

    static var queue: [String: Any] {
        let q: [String: Any] = ["id": 11, "name": "Late night drives", "cursor_index": 3, "position_ms": 74_000, "rev": 4,
         "repeat": "off", "total": 18, "window_from": 0, "items": queueItems]
        return q
    }

    static let queues: [[String: Any]] = [
        ["id": 11, "name": "Late night drives", "cursor_index": 3, "position_ms": 74_000, "rev": 4, "repeat": "off", "items": 18],
        ["id": 12, "name": "Now", "cursor_index": 7, "position_ms": 0, "rev": 9, "repeat": "off", "items": 31],
        ["id": 13, "name": "Station: Mira Holt", "cursor_index": 12, "position_ms": 0, "rev": 2, "repeat": "off", "items": 40,
         "station": ["id": 4, "kind": "artist", "playlist_id": 4] as [String: Any]],
        ["id": 14, "name": "Sunday slow", "cursor_index": 0, "position_ms": 0, "rev": 1, "repeat": "off", "items": 10],
    ]

    static var home: [String: Any] {
        let mix: [[String: Any]] = tracks.shuffledStable().prefix(8).map { t -> [String: Any] in
            ["where": "library", "why": "", "track": t]
        }
        let again: [[String: Any]] = tracks.reversed().prefix(8).map { t -> [String: Any] in
            ["where": "library", "why": "loved, then left", "track": t]
        }
        let sections: [[String: Any]] = [
            ["id": "mix", "name": "Made for you", "items": mix],
            ["id": "again", "name": "Back in the box", "items": again],
        ]
        return ["sections": sections]
    }

    static func search(_ q: String) -> [String: Any] {
        let l = tracks.filter { t in
            let title = (t["title"] as? String ?? "").lowercased()
            let artist = ((t["artists"] as? [String]) ?? []).joined().lowercased()
            return q.isEmpty || title.contains(q.lowercased()) || artist.contains(q.lowercased())
        }
        let remote: [[String: Any]] = [
            ["video_id": "a1", "title": "\(q.capitalized) (Live at the Pier)", "artists": ["The Low Arches"], "duration_ms": 284_000, "known": false, "cover_url": "/art/remote?u=one"],
            ["video_id": "a2", "title": "\(q.capitalized) Theme", "artists": ["Copperfield Strings"], "duration_ms": 198_000, "known": false, "cover_url": "/art/remote?u=second"],
            ["video_id": "a3", "title": "Into the \(q.capitalized)", "artists": ["Halvard"], "duration_ms": 312_000, "known": false, "cover_url": "/art/remote?u=third!"],
        ]
        return ["local": Array(l.prefix(6)), "remote": remote]
    }

    /// A made-up cover: the colour, a disc, the light on it.
    static func cover(seed: Int) -> Data {
        let size = CGSize(width: 300, height: 300)
        let hex = colours[abs(seed) % colours.count]
        let (r, g, b) = hex.hexRGB ?? (0.5, 0.5, 0.5)
        let base = UIColor(red: r, green: g, blue: b, alpha: 1)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            let colors = [base.cgColor, UIColor(red: r * 0.35, green: g * 0.35, blue: b * 0.4, alpha: 1).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                c.drawLinearGradient(grad, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let k = CGFloat(abs(seed * 37) % 100) / 100
            c.setFillColor(UIColor(white: 1, alpha: 0.10 + 0.1 * k).cgColor)
            c.fillEllipse(in: CGRect(x: 40 + 60 * k, y: 70 - 30 * k, width: 190, height: 190))
            c.setFillColor(UIColor(white: 0, alpha: 0.25).cgColor)
            c.fillEllipse(in: CGRect(x: 120 + 60 * k, y: 150 - 30 * k, width: 30, height: 30))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.18).cgColor)
            c.setLineWidth(3)
            for i in 0..<4 {
                let y = 30 + CGFloat(i) * 14 + 200 * k
                c.move(to: CGPoint(x: 20, y: y))
                c.addLine(to: CGPoint(x: 280, y: y + 40 * (1 - k)))
            }
            c.strokePath()
        }
        return img.pngData() ?? Data()
    }
}

extension Array {
    /// The same "random" order every run, so screenshots are comparable.
    func shuffledStable() -> [Element] {
        var out = self
        var s: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let j = Int((s >> 33) % UInt64(i + 1))
            out.swapAt(i, j)
        }
        return out
    }
}

/// Which screen a demo launch opens on.
enum DemoScreen {
    static var name: String? {
        guard UserDefaults.standard.bool(forKey: "demo") else { return nil }
        return UserDefaults.standard.string(forKey: "screen")
    }

    @MainActor
    static func setUp(_ app: AppModel) {
        guard let screen = name else { return }
        if screen != "login", let d = try? JSONSerialization.data(withJSONObject: DemoData.queue),
           let q: QueueState = try? API.decode(d) {
            app.player.showcase(q, index: 3, elapsed: 74, playing: true)
        }
        switch screen {
        case "search": app.tab = .search
        case "library", "playlist": app.tab = .library
        case "nowplaying", "queue": app.nowPlayingOpen = true
        case "settings": app.showSettings = true
        default: app.tab = .home
        }
    }
}
