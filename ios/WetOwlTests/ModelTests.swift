import XCTest
@testable import WetOwl

final class ModelTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String) throws -> T {
        try API.decode(Data(json.utf8))
    }

    func testPlaylistListSendsACountAndOneSendsTheSongs() throws {
        let list: Lossy<Playlist> = try decode("""
        [{"id": 1, "name": "Favourites", "kind": "favourites", "items": 14022, "pinned": false},
         {"id": 2, "name": "Late", "kind": "local", "items": 3, "cover_url": "/playlists/2/cover", "cover_version": "ab"}]
        """)
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items[0].count, 14022)
        XCTAssertNil(list.items[0].tracks)
        XCTAssertTrue(list.items[0].isFavourites)

        let one: Playlist = try decode("""
        {"id": 2, "name": "Late", "kind": "local", "items": [
            {"id": 7, "title": "A", "artists": ["X"], "state": "ready", "stream_url": "/tracks/7/stream", "pos": 0},
            {"id": "broken"},
            {"id": 8, "title": "B", "artists": [], "state": "pending", "pos": 1}
        ]}
        """)
        XCTAssertEqual(one.tracks?.map { $0.id }, [7, 8], "the broken row is skipped, not the list")
        XCTAssertEqual(one.count, 2)
        XCTAssertTrue(one.tracks![0].isReady)
        XCTAssertFalse(one.tracks![1].isReady)
        XCTAssertEqual(one.tracks![1].artistLine, "Unknown artist")
    }

    func testQueueWindowAndRepeat() throws {
        let q: QueueState = try decode("""
        {"id": 5, "name": "Now", "cursor_index": 601, "position_ms": 1200, "rev": 9, "repeat": "all",
         "total": 1400, "window_from": 600, "station": {"id": 3, "kind": "track", "playlist_id": 44},
         "items": [{"id": 1, "title": "a", "item_id": 100}, {"id": 2, "title": "b", "item_id": 101},
                   {"id": 1, "title": "a", "item_id": 102}]}
        """)
        XCTAssertEqual(q.repeatMode, .all)
        XCTAssertTrue(q.isWindowed)
        XCTAssertTrue(q.isStation)
        XCTAssertEqual(q.track(at: 601)?.id, 2)
        XCTAssertNil(q.track(at: 0))
        XCTAssertEqual(q.index(ofItem: 102), 602)
        XCTAssertEqual(q.lastIndex, 602)
        XCTAssertEqual(q.nearest(trackId: 1, around: 602), 602)
        XCTAssertEqual(q.nearest(trackId: 1, around: 599), 600)

        let list: Lossy<QueueState> = try decode("""
        [{"id": 5, "name": "Now", "cursor_index": 2, "items": 31, "shared_from": null}]
        """)
        XCTAssertEqual(list.items.first?.total, 31)
        XCTAssertEqual(list.items.first?.items.count, 0)
    }

    func testLocalQueueEditsMatchTheHouse() {
        let tracks = (1...5).map { Track(id: $0, title: "\($0)", artists: []) }
        var q = QueueState(id: 1, name: "q", items: tracks, cursorIndex: 2)
        q.move(from: 0, to: 2)   // lifted out, then put at 2
        XCTAssertEqual(q.items.map { $0.id }, [2, 3, 1, 4, 5])
        q.remove(at: 0)
        XCTAssertEqual(q.items.map { $0.id }, [3, 1, 4, 5])
        XCTAssertEqual(q.cursorIndex, 1, "removing above the cursor keeps it on the same song")
        q.insert([Track(id: 9, title: "9", artists: [])], at: 2)
        XCTAssertEqual(q.items.map { $0.id }, [3, 1, 9, 4, 5])
        XCTAssertEqual(q.total, 5)
    }

    func testQueueSurvivesTheDiskRoundTrip() throws {
        var t = Track(id: 3, title: "T", artists: ["A", "B"], durationMs: 200_000, coverUrl: "/tracks/3/cover",
                      coverColor: "#aabbcc", streamUrl: "/tracks/3/stream")
        t.itemId = 77
        t.gainDb = -4.5
        var q = QueueState(id: 9, name: "Now", items: [t], cursorIndex: 0)
        q.repeatMode = .one
        q.station = StationRef(id: 2, kind: "artist", playlistId: 8)
        let data = try XCTUnwrap(API.encode(q))
        let back: QueueState = try API.decode(data)
        XCTAssertEqual(back, q)
    }

    func testPicksWithoutATrackOrAHitAreDropped() throws {
        let home: HomePicks = try decode("""
        {"sections": [{"id": "mix", "name": "Made for you", "items": [
            {"where": "new", "hit": {"video_id": "v1", "title": "N", "artists": ["Z"]}},
            {"where": "library"},
            {"where": "library", "track": {"id": 4, "title": "L"}}
        ]}]}
        """)
        XCTAssertEqual(home.sections.first?.items.map { $0.id }, ["vv1", "t4"])
    }

    func testFormBodyAndServerAddress() {
        XCTAssertEqual(API.formBody(["user": "a b", "password": "p&w=1"]), "password=p%26w%3D1&user=a%20b")
        XCTAssertEqual(API.normalise(" 89-58-49-140.nip.io/ "), "https://89-58-49-140.nip.io")
        XCTAssertEqual(API.normalise(""), API.defaultServer)
    }

    func testCoverAndStreamAddresses() {
        let api = API(base: "https://house.example", token: "t", transport: LiveTransport())
        var t = Track(id: 3, title: "T", artists: [], coverUrl: "/tracks/3/cover", streamUrl: "/tracks/3/stream")
        t.coverVersion = "ab12"
        XCTAssertEqual(api.coverURL(t, small: true)?.absoluteString, "https://house.example/tracks/3/cover?size=sm&v=ab12")
        XCTAssertEqual(api.streamURL(t)?.absoluteString, "https://house.example/tracks/3/stream")
    }

    func testErrorsSayWhatHappened() {
        let d = Data(#"{"detail": [{"msg": "field required"}, {"msg": "too short"}]}"#.utf8)
        XCTAssertEqual(API.detail(d, 422), "field required. too short")
        XCTAssertEqual(API.detail(Data("<!DOCTYPE html>".utf8), 502), "The house answered with a web page (502)")
        XCTAssertTrue(APIError.from(URLError(.notConnectedToInternet)).isOffline)
    }

    func testTimeFormatting() {
        XCTAssertEqual(formatTime(0), "0:00")
        XCTAssertEqual(formatTime(74.9), "1:14")
        XCTAssertEqual(formatTime(3723), "1:02:03")
        XCTAssertEqual(formatTime(.nan), "0:00")
    }
}

final class BrowseTests: XCTestCase {
    func testLyricsWithSeveralStampsAndTags() {
        let lines = LyricsParser.parse("[ar:Someone]\n[00:10.50][01:00.00] chorus\n[00:05.00] verse\n[00:20.00]\n")
        XCTAssertEqual(lines.map { $0.time }, [5, 10.5, 20, 60])
        XCTAssertEqual(lines.map { $0.text }, ["verse", "chorus", "", "chorus"])
        XCTAssertNil(LyricsParser.index(of: lines, at: 2))
        XCTAssertEqual(LyricsParser.index(of: lines, at: 10.4), 1, "a line lights a moment early")
        XCTAssertEqual(LyricsParser.index(of: lines, at: 59), 2)
        XCTAssertEqual(LyricsParser.index(of: lines, at: 500), 3)
    }

    func testArtistPageKeepsWhatDecodes() throws {
        let d: ArtistDetail = try API.decode(Data("""
        {"artist": {"name": "Mira", "image": null, "fans": 12},
         "albums": [{"remote_id": "1", "title": "A", "have": 2}, {"title": "no id"}],
         "top": [{"remote_id": "9", "title": "T", "artists": [null, "Mira"], "track": {"id": 4, "title": "T"}}],
         "tracks": [{"id": 4, "title": "T"}]}
        """.utf8))
        XCTAssertEqual(d.artist.name, "Mira")
        XCTAssertEqual(d.albums.map { $0.title }, ["A"])
        XCTAssertEqual(d.top.first?.artists, ["Mira"])
        XCTAssertEqual(d.top.first?.track?.id, 4)
    }

    func testRecordPagePlaysOnlyWhatIsHere() throws {
        let d: AlbumDetail = try API.decode(Data("""
        {"album": {"name": "Lib", "release_name": "Release", "artist": "X"},
         "tracks": [{"pos": 1, "title": "a", "track": {"id": 1, "title": "a"}}, {"pos": 2, "title": "b"}],
         "extra": [{"id": 7, "title": "z"}]}
        """.utf8))
        XCTAssertEqual(d.album.name, "Release")
        XCTAssertEqual(d.playable.map { $0.id }, [1, 7])
    }

    func testDevicesAndPages() throws {
        let l: DeviceList = try API.decode(Data("""
        {"this": 3, "devices": [{"id": 3, "name": "iPhone", "this": true}, {"id": 4, "name": "Linux desk", "live": true, "playing": true, "position_ms": 1000}]}
        """.utf8))
        XCTAssertEqual(l.this, 3)
        XCTAssertTrue(l.devices[0].isThis)
        XCTAssertEqual(l.devices[1].icon, "desktopcomputer")
        let p: Page<AlbumSummary> = try API.decode(Data(#"{"items": [{"name": "R", "artist": "A", "tracks": 3}], "total": 40}"#.utf8))
        XCTAssertEqual(p.total, 40)
        XCTAssertEqual(p.items.first?.id, "A\u{1}R")
    }

    func testOnlyNewerBuildsAreOffered() {
        XCTAssertTrue(Updates.isNewer("202611080900", than: "202611071238"))
        XCTAssertFalse(Updates.isNewer("202611071238", than: "202611071238"))
        XCTAssertFalse(Updates.isNewer("202611080900", than: "1"), "a build made by hand is never nagged")
    }
}
