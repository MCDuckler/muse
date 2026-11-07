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

final class JamTests: XCTestCase {
    func testTheJamYouAreIn() throws {
        let j: Jam = try API.decode(Data("""
        {"id": 7, "code": "K7MQ2P", "queue_id": 11, "host": "joe", "is_host": false,
         "members": [{"user_id": 2, "name": "joe", "host": true, "online": true},
                     {"user_id": 1, "name": "chris", "host": false, "online": null},
                     {"name": "no id"}],
         "listening": 2, "started_at": "2026-11-07T12:00:00Z",
         "now_playing": {"id": 4, "title": "Paper Moons"},
         "playback": {"track_id": 4, "item_id": 1003, "position_ms": 74000, "playing": true, "age_ms": 1500, "seq": 1762500000000}}
        """.utf8))
        XCTAssertEqual(j.title, "joe's jam")
        XCTAssertEqual(j.members.map { $0.name }, ["joe", "chris"], "a member without an id is skipped")
        XCTAssertFalse(j.members[1].online)
        XCTAssertEqual(j.nowPlaying?.id, 4)
        XCTAssertEqual(j.playback?.seconds, 75.5, "a playing room has moved on by the age of the news")
        XCTAssertEqual(j.playback?.seq, 1_762_500_000_000)
        XCTAssertEqual(j.crowd, "2 listening")

        let mine: Jam = try API.decode(Data(#"{"id": 8, "code": "Q3RT7Z", "queue_id": 3, "is_host": true, "members": []}"#.utf8))
        XCTAssertEqual(mine.title, "Your jam")
        XCTAssertEqual(mine.crowd, "Just you so far")
    }

    func testRunningJamsAndPeople() throws {
        let p: Page<RunningJam> = try API.decode(Data("""
        {"items": [{"id": 8, "code": "Q3RT7Z", "queue_id": 21, "host": "joe", "queue": "Friday", "listening": 3,
                    "playing": "Signal Fire", "by": null, "joined": false}]}
        """.utf8))
        XCTAssertEqual(p.items.first?.nowLine, "Signal Fire")
        let people: Page<Person> = try API.decode(Data(#"{"items": [{"id": 2, "name": "joe", "online": true, "last_seen": null}]}"#.utf8))
        XCTAssertEqual(people.items.first?.online, true)
    }

    func testPlaybackFromALiveEvent() {
        let pb = JamPlayback(event: ["jam_id": 7, "what": "playback", "track_id": 9, "position_ms": 12_000,
                                     "playing": false, "item_id": NSNull(), "seq": 5])
        XCTAssertEqual(pb?.trackId, 9)
        XCTAssertNil(pb?.itemId)
        XCTAssertEqual(pb?.seconds, 12)
        XCTAssertEqual(pb?.playing, false)
        XCTAssertNil(JamPlayback(event: ["jam_id": 7, "what": "joined"]))
    }

    func testTheRoomsClock() {
        XCTAssertEqual(RoomClock.carried(60, playing: true, since: 2.5, length: 200), 62.5)
        XCTAssertEqual(RoomClock.carried(60, playing: false, since: 30, length: 200), 60, "a paused room stays where it is")
        XCTAssertEqual(RoomClock.carried(199, playing: true, since: 5, length: 200), 200, "never past the end of the song")
        XCTAssertEqual(RoomClock.carried(60, playing: true, since: 600, length: 200), 60, "old news is not carried forward")
        XCTAssertTrue(RoomClock.isStale(4, heard: 5))
        XCTAssertFalse(RoomClock.isStale(5, heard: 5))
        XCTAssertFalse(RoomClock.isStale(nil, heard: 5), "a host that does not count is believed")
        XCTAssertFalse(RoomClock.isStale(1, heard: nil))
    }

    func testAPickedSongGoesStraightAfterTheOnePlaying() {
        XCTAssertEqual(RoomClock.nextSlot(for: 9, playing: 4), 5)
        XCTAssertEqual(RoomClock.nextSlot(for: 1, playing: 4), 4, "lifted out from above, the rows close up")
        var q = QueueState(id: 1, name: "q", items: (1...6).map { Track(id: $0, title: "\($0)", artists: []) }, cursorIndex: 2)
        q.move(from: 5, to: RoomClock.nextSlot(for: 5, playing: 2))
        XCTAssertEqual(q.items.map { $0.id }, [1, 2, 3, 6, 4, 5])
        q.move(from: 0, to: RoomClock.nextSlot(for: 0, playing: 2))
        XCTAssertEqual(q.items.map { $0.id }, [2, 3, 1, 6, 4, 5], "song 3 (playing) is now row 1, the pick row 2")
    }

    func testTheHostsCountOnlyGoesUp() {
        let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(RoomClock.nextSeq(after: 0, now: t), 1_000_000)
        XCTAssertEqual(RoomClock.nextSeq(after: 1_000_000, now: t), 1_000_001, "two in the same millisecond")
        XCTAssertTrue(RoomClock.justAhead(hostOn: 200, hostAt: 195, hereAt: 2))
        XCTAssertFalse(RoomClock.justAhead(hostOn: 200, hostAt: 120, hereAt: 2))
    }
}
