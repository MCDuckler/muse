package dance.duckduck.wetowl

import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest

/**
 * A house that answers from fixtures: enough music for every screen to have something
 * real-looking on it, and a record of what the app asked.
 */
class FakeHouse {
    val server = MockWebServer()
    val asked = mutableListOf<String>()

    private data class Song(val id: Int, val title: String, val artist: String, val album: String,
                            val secs: Int, val colour: String, val state: String = "ready")

    private val songs = listOf(
        Song(1, "Strobe Garden", "Ibis Vale", "Low Tide Atlas", 274, "#d0573f"),
        Song(2, "Pale Machines", "Ibis Vale", "Low Tide Atlas", 241, "#3f7fd0"),
        Song(3, "Night Bus to Kreuzberg", "Hollow Sun", "Concrete Bloom", 318, "#8a4fd6"),
        Song(4, "Velvet Static", "Maara", "Hear Me Neigh", 396, "#d6a24f"),
        Song(5, "The Horse Track", "Maara", "Hear Me Neigh", 377, "#4fd69a"),
        Song(6, "Surveillance", "FJAAK", "Surveillance", 360, "#d64f86"),
        Song(7, "Surveillance (snippet)", "FJAAK", "", 90, "#d64f86"),
        Song(8, "Juicy Tracksuit", "Maara", "Fancy Feast", 384, "#4fb8d6"),
        Song(9, "Cold Coffee Sunrise", "Lune Ferrari", "Mornings", 205, "#c6d64f", state = "pending"),
        Song(10, "Half Light", "Hollow Sun", "Concrete Bloom", 262, "#d67a4f"),
    )

    /** Songs that finished fetching since the fixtures were written. */
    val nowReady = java.util.Collections.synchronizedSet(mutableSetOf<Int>())

    /** When set, this person is a guest in a jam on queue 2. */
    @Volatile var inJam = false

    /** What /events says the next time it is opened (then the line closes). */
    @Volatile var events: String? = null

    private fun track(s0: Song, item: Int? = null) = buildString {
        val s = if (s0.id in nowReady) s0.copy(state = "ready") else s0
        append("""{"id":${s.id},"title":"${s.title}","artists":["${s.artist}"],"album":"${s.album}",""")
        append(""""duration_ms":${s.secs * 1000},"state":"${s.state}","cover_url":"/tracks/${s.id}/cover",""")
        append(""""cover_color":"${s.colour}","cover_version":"v${s.id}",""")
        if (s.state == "ready") append(""""stream_url":"/tracks/${s.id}/stream",""")
        if (item != null) append(""""item_id":$item,""")
        append(""""source":"youtube"}""")
    }

    private fun queue(id: Int, name: String, ids: List<Int>, cursor: Int = 0) =
        """{"id":$id,"name":"$name","cursor_index":$cursor,"position_ms":61000,"rev":3,"repeat":"all",
            "total":${ids.size},"window_from":0,"items":[${ids.mapIndexed { i, s -> track(songs[s - 1], 100 * id + i) }.joinToString(",")}]}"""

    private val queues get() = mapOf(
        1 to queue(1, "Tonight", listOf(1, 3, 4, 2, 6, 10, 9, 5, 8), cursor = 1),
        2 to queue(2, "Gym", listOf(8, 5, 6)),
        3 to queue(3, "Sunday", listOf(10, 2)),
    )

    private fun body(path: String, query: String?): String? = when {
        path == "/auth/login" -> """{"token":"t","user":"joe"}"""
        path == "/events" -> "event: hello\ndata: {}\n\n" + (events?.also { events = null } ?: "")
        path == "/me" -> """{"user":"joe"}"""
        path == "/queues" -> "[" + queues.map { (id, q) ->
            q.replace(Regex("\"items\":\\[.*]}$", RegexOption.DOT_MATCHES_ALL), "\"items\":${if (id == 1) 9 else if (id == 2) 3 else 2}}")
        }.joinToString(",") + "]"
        path.matches(Regex("/queues/\\d+")) -> queues[path.substringAfterLast('/').toInt()]
        path == "/playlists" -> """[
            {"id":1,"name":"Liked","kind":"favourites","items":214,"pinned":true},
            {"id":2,"name":"Warehouse at 4am","kind":"local","items":58,"cover_url":"/playlists/2/cover"},
            {"id":3,"name":"Slow Sundays","kind":"local","items":31,"cover_url":"/playlists/3/cover"},
            {"id":4,"name":"Discover Weekly","kind":"spotify","items":30,"saved":true,"owner_name":"Spotify","cover_url":"/playlists/4/cover"},
            {"id":5,"name":"Night drives","kind":"local","items":44,"cover_url":"/playlists/5/cover","folder_id":7},
            {"id":6,"name":"Autobahn","kind":"local","items":12,"folder_id":7}]"""
        path == "/playlist-folders" -> """{"items":[{"id":7,"name":"Driving","count":2}]}"""
        path == "/library/smart" -> """{"lists":[{"id":"never","name":"Never played","blurb":"In the library, never on","count":412},
            {"id":"most","name":"Most played","blurb":"","count":100},{"id":"forgotten","name":"Forgotten","blurb":"","count":80}],
            "decades":[{"id":"2010s","name":"2010s","blurb":"","count":900}]}"""
        path.startsWith("/library/smart/") -> """{"name":"Never played","blurb":"In the library, never on","items":[${listOf(2, 5, 8).joinToString(",") { track(songs[it - 1]) }}]}"""
        path == "/library/history" -> """{"items":[${listOf(3, 6, 1, 10, 5, 4).joinToString(",") { track(songs[it - 1]) }}]}"""
        path == "/recommend/dislikes" -> """{"track_ids":[7]}"""
        path.matches(Regex("/tracks/\\d+")) -> track(songs[path.substringAfterLast('/').toInt() - 1])
        path == "/playlists/2/suggested" -> """{"items":[${listOf(2, 8).joinToString(",") { track(songs[it - 1]) }}]}"""
        path == "/library/stats" -> """{"totals":{"plays":214,"minutes":861,"tracks":73},
            "songs":[${listOf(3 to 21, 6 to 17, 4 to 12, 1 to 9, 10 to 6).joinToString(",") { (i, n) -> track(songs[i - 1]).dropLast(1) + ""","plays":$n}""" }}],
            "artists":[{"name":"Maara","plays":41},{"name":"Hollow Sun","plays":30},{"name":"FJAAK","plays":17}],
            "albums":[{"name":"Concrete Bloom","artist":"Hollow Sun","plays":27,"cover_url":"/art/2"},{"name":"Hear Me Neigh","artist":"Maara","plays":20,"cover_url":"/art/3"}]}"""
        path == "/playlists/2" -> """{"id":2,"name":"Warehouse at 4am","kind":"local","cover_url":"/playlists/2/cover","sort":"manual","editable":true,
            "items":[${listOf(6, 4, 1, 3, 7, 9, 10).joinToString(",") { track(songs[it - 1]) }}]}"""
        path == "/favourites" -> """{"playlist_id":1,"track_ids":[3,4,6]}"""
        path == "/history" -> "[" + listOf(3, 6, 1, 10, 5).joinToString(",") { track(songs[it - 1]) } + "]"
        path == "/recommend/home" -> """{"sections":[
            {"id":"mix","name":"Made for you","items":[${listOf(4, 2, 10, 8).joinToString(",") { """{"where":"library","why":"","track":${track(songs[it - 1])}}""" }}]},
            {"id":"back","name":"Back again","items":[${listOf(5, 1, 3).joinToString(",") { """{"where":"library","why":"","track":${track(songs[it - 1])}}""" }}]}]}"""
        path.endsWith("/marks") -> """{"owner_id":1,"track_id":3,"strokes":[
            {"stroke_id":"a","ink":1,"width":2.5,"points":[0.2,0.3,0.3,0.25,0.4,0.3,0.5,0.25,0.6,0.3,0.7,0.25,0.8,0.3],"done":true,"author_id":1},
            {"stroke_id":"b","ink":2,"width":1,"points":[0.2,0.6,0.8,0.6,0.8,0.8,0.2,0.8,0.2,0.6],"done":true,"author_id":2},
            {"stroke_id":"c","ink":4,"width":4,"points":[0.5,0.45,0.5,0.5],"done":true,"author_id":2}]}"""
        path == "/discover/cards" -> """{"items":[{"track":${track(songs[3])},"list":"radar","list_name":"Release Radar","why":"new from somebody you follow","service":"bandcamp"},
            {"track":${track(songs[0])},"list":"weekly","list_name":"Discover Weekly","why":"new to you this week","service":"soundcloud"}],"total":2}"""
        path.startsWith("/discover/cards/") -> """{"genres":["minimal","tech house","berlin"],"comments":[
            {"name":"lowfreq","text":"that bassline at 3:10 though"},{"name":"mira","text":"played this three times on the way home"}],
            "about":"Recorded live to tape in a Neukölln basement.","source":"bandcamp","url":"https://maara.bandcamp.com"}"""
        path.endsWith("/lyrics") -> """{"synced":"[00:00.00]Night bus, night bus\n[00:30.00]Kreuzberg lights go by\n[01:00.00]Nobody here but the driver and I\n[01:30.00]Night bus, night bus","plain":null}"""
        path == "/jams/current" -> if (!inJam) """{"jam":null}""" else """{"jam":{"id":5,"code":"OWL42","queue_id":2,"host":"mira","is_host":false,
            "members":[{"user_id":7,"name":"mira","host":true,"online":true},{"user_id":1,"name":"joe","host":false,"online":true}],"listening":2}}"""
        path == "/social/people" -> """{"you":1,"people":[
            {"id":7,"name":"mira","songs":812,"playlists":14,"last_seen":"2026-11-24T04:00:00","playing":{"track":${track(songs[7])},"queue":"Late","now":true},"jam":{"code":"OWL42"}},
            {"id":8,"name":"tobi","songs":301,"playlists":3,"last_seen":"2026-11-23T20:00:00","playing":{"track":${track(songs[1])},"queue":"Run","now":true}},
            {"id":9,"name":"kat","songs":55,"playlists":1}]}"""
        path == "/devices" -> """{"this":2,"devices":[
            {"id":2,"name":"Pixel 9","platform":"android","kind":"phone","this":true,"live":true,"playing":false,"position_ms":0,"age_ms":0},
            {"id":3,"name":"Desk","platform":"linux","kind":"desktop","this":false,"live":true,"playing":true,"position_ms":90000,"age_ms":2000,
             "queue":"Gym","queue_id":2,"item_id":201,"track":${track(songs[4])}},
            {"id":4,"name":"iPhone","platform":"ios","this":false,"live":false,"playing":false,"position_ms":0,"age_ms":0,"last_seen":"2026-11-20T10:00:00"}]}"""
        path == "/discover" -> """{"lists":[
              {"slug":"mix:1","name":"Daily Mix 1","blurb":"Maara, Hollow Sun and more","count":4,"kind":"mix","tracks":[${listOf(4, 3, 10, 8).joinToString(",") { track(songs[it - 1]) }}]},
              {"slug":"radar","name":"Release Radar","blurb":"New from who you follow","count":3,"kind":"radar","tracks":[${listOf(6, 1, 2).joinToString(",") { track(songs[it - 1]) }}]},
              {"slug":"weekly","name":"Discover Weekly","blurb":"","count":2,"kind":"weekly","tracks":[${listOf(5, 2).joinToString(",") { track(songs[it - 1]) }}]}],
            "building":false,
            "stations":{"yours":[{"id":1,"playlist_id":9,"name":"Velvet Static radio","kind":"track","count":30,"cover_track":4}],
              "artists":[{"name":"Maara","cover_track":5},{"name":"FJAAK","cover_track":6}],"tracks":[],
              "genres":[{"genre":"techno","following":true},{"genre":"electro","following":true},{"genre":"breaks","following":false}]},
            "feed":{"items":[
              {"source":"artist","provider":"deezer","album_id":"77","title":"Ultraviolet Hooves","artist":"Maara","cover":"/art/u1","release_date":"2026-11-20","record_type":"ep","unseen":true,"in_library":false,"upcoming":false},
              {"source":"artist","provider":"bandcamp","album_id":"https://x.bandcamp.com/album/y","title":"Pressure Systems","artist":"Hollow Sun","via":"Kalahari Oyster Cult","cover":"/art/u2","release_date":"2026-12-04","record_type":"album","unseen":false,"in_library":false,"upcoming":true},
              {"source":"genre","provider":"mb","title":"Warehouse Tools Vol. 3","artist":"Various","genre":"techno","cover":"/art/u3","release_date":"2026-11-14","record_type":"compile","unseen":false,"in_library":false,"upcoming":false}]},
            "genres":{"following":["techno","electro"],"suggested":[{"genre":"breaks"}]},
            "artists":[{"name":"DJ Heartstring","because":"people who play Maara and FJAAK play this"},{"name":"Elli Acula","because":"people who play Hollow Sun play this"}]}"""
        path == "/search/everything" -> """{"items":[
            {"kind":"artist","place":"library","id":"FJAAK","title":"FJAAK","subtitle":"2 songs","tracks":2},
            {"kind":"song","place":"library","id":"6","title":"Surveillance","subtitle":"FJAAK","track":${track(songs[5])}},
            {"kind":"album","place":"ytmusic","id":"MPREb_x","title":"Live at Tresor","subtitle":"FJAAK","year":"2023","cover_url":"/art/remote?u=y"},
            {"kind":"song","place":"soundcloud","id":"sc1","title":"Gloria (Edit)","subtitle":"FJAAK","duration_ms":331000},
            {"kind":"video","place":"youtube","id":"v1","title":"FJAAK Boiler Room Berlin","subtitle":"Boiler Room","duration_ms":3720000,"cover_url":"/art/remote?u=z"},
            {"kind":"label","place":"bandcamp","id":"https://fjaak.bandcamp.com","title":"FJAAK","subtitle":"Berlin"}],
            "notes":{"spotify":"not linked"}}"""
        path == "/search" -> """{"local":[${track(songs[5])},${track(songs[6])}],
            "artists":[{"name":"FJAAK","tracks":2}],
            "remote":[{"video_id":"abc","title":"Surveillance (Live)","artists":["FJAAK"],"album":"Live at Tresor","duration_ms":402000,"cover_url":"/art/remote?u=x"},
                      {"video_id":"def","title":"Gloria","artists":["FJAAK"],"duration_ms":331000}]}"""
        path == "/library/artists/detail" -> """{"artist":{"name":"Maara","image":"/art/maara","fans":1070,"remote_id":"2",
                "following":true,"bandcamp_url":"https://maara.bandcamp.com"},
            "namesakes":[{"key":"yt:UCX","label":"Mavi Zarf · K A R B O N","songs":10}],
            "top":[{"title":"Velvet Static","artists":["Maara"],"track":${track(songs[3])}},{"title":"The Horse Track","artists":["Maara"],"track":${track(songs[4])}}],
            "albums":[{"remote_id":"b1","title":"Hear Me Neigh","release_date":"2021-05-01","record_type":"album","have":2,"cover":"/art/b1"},
                      {"remote_id":"b2","title":"Potion Activated","release_date":"2019-03-01","record_type":"ep","have":0,"cover":"/art/b2"},
                      {"remote_id":"https://maara.bandcamp.com/album/fancy-feast","title":"Fancy Feast","record_type":"album","have":1,
                       "cover":"/art/b3","source":"bandcamp","url":"https://maara.bandcamp.com/album/fancy-feast"}],
            "tracks":[${listOf(4, 5, 8).joinToString(",") { track(songs[it - 1]) }}]}"""
        path == "/library/albums/detail" -> """{"album":{"name":"Concrete Bloom","artist":"Hollow Sun","release_date":"2024-02-02","record_type":"album","cover":"/art/cb"},
            "tracks":[{"pos":1,"title":"Night Bus to Kreuzberg","artists":["Hollow Sun"],"track":${track(songs[2])}},
                      {"pos":2,"title":"Paper Moons","artists":["Hollow Sun"],"duration_ms":244000},
                      {"pos":3,"title":"Half Light","artists":["Hollow Sun"],"track":${track(songs[9])}}],"extra":[]}"""
        path == "/library/artists" -> """{"total":3,"items":[{"name":"FJAAK","tracks":2,"albums":1},{"name":"Hollow Sun","tracks":2,"albums":1},{"name":"Maara","tracks":34,"albums":5}]}"""
        path == "/library/albums" -> """{"total":4,"items":[{"name":"Low Tide Atlas","artist":"Ibis Vale","tracks":2,"year":2023,"cover_url":"/art/1"},
            {"name":"Concrete Bloom","artist":"Hollow Sun","tracks":2,"year":2024,"cover_url":"/art/2"},
            {"name":"Hear Me Neigh","artist":"Maara","tracks":2,"year":2021,"cover_url":"/art/3"},{"name":"Fancy Feast","artist":"Maara","tracks":1,"cover_url":"/art/4"}]}"""
        path == "/library/tracks" -> """{"total":10,"items":[${songs.joinToString(",") { track(it) }}]}"""
        else -> null
    }

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.url.encodedPath
                synchronized(asked) { asked.add("${request.method} $path") }
                val text = body(path, request.url.query) ?: "{}"
                return MockResponse.Builder().code(200).addHeader("Content-Type", "application/json").body(text).build()
            }
        }
        server.start()
    }

    val base: String get() = server.url("/").toString().trimEnd('/')
}
