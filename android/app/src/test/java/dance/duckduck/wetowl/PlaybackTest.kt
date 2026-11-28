package dance.duckduck.wetowl

import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import dance.duckduck.wetowl.core.Api
import dance.duckduck.wetowl.core.QueueState
import kotlinx.serialization.json.jsonObject
import kotlinx.coroutines.launch
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = android.app.Application::class)
class PlaybackTest {
    private lateinit var house: FakeHouse
    private lateinit var store: Store

    @Before
    fun setUp() {
        house = FakeHouse()
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.getSharedPreferences("wetowl", Context.MODE_PRIVATE).edit()
            .putString("server", house.base).putString("token", "t").putString("user", "joe").commit()
        store = Store(context)
        store.start()
        val end = System.currentTimeMillis() + 5000
        while (store.playback.now.value.track == null && System.currentTimeMillis() < end) {
            shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(20)
        }
    }

    @After
    fun tearDown() {
        store.playback.release()
        store.offline.manager.release()
        store.offline.cache.release()
        house.server.close()
    }

    private fun ids() = (0 until store.playback.exo.mediaItemCount).map { store.playback.exo.getMediaItemAt(it).mediaId }

    @Test
    fun `the queue opens where it was, and only playable songs reach the player`() {
        val now = store.playback.now.value
        assertEquals(1, now.queue?.id)
        assertEquals("Night Bus to Kreuzberg", now.track?.name)
        // Nine rows, one still on its way: eight items.
        assertEquals(8, store.playback.exo.mediaItemCount)
        assertEquals("i101", store.playback.exo.currentMediaItem?.mediaId)
    }

    @Test
    fun `rows moved and removed around the song playing never touch it`() {
        val p = store.playback
        val before = p.exo.currentMediaItem
        val q = p.now.value.queue!!
        // The house's answer to: the last row moved to the top, the first one taken out.
        val items = q.items.toMutableList().apply { add(0, removeAt(size - 1)); removeAt(1) }
        p.adopt(q.copy(items = items, rev = q.rev + 1))
        val end = System.currentTimeMillis() + 3000
        while (p.now.value.queue?.rev != q.rev + 1 && System.currentTimeMillis() < end) {
            shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(20)
        }

        assertEquals("the very same item is still loaded", before, p.exo.currentMediaItem)
        assertEquals(items.filter { it.isReady }.map { it.rowKey }, ids())
        assertEquals("Night Bus to Kreuzberg", p.now.value.track?.name)
        assertEquals(items.indexOfFirst { it.rowKey == "i101" }, p.now.value.row)
    }

    @Test
    fun `a queue answered with odd fields still reads`() {
        val o = Api.JSON.parseToJsonElement(
            """{"id":9,"name":"X","items":[{"id":1,"title":"A","artists":null,"duration_ms":"x"},{"nope":true}],
               "station":{"id":4},"repeat":"one"}""").jsonObject
        val q = QueueState.from(o)
        assertEquals(1, q.items.size)
        assertEquals(4, q.stationId)
        assertEquals(dance.duckduck.wetowl.core.RepeatMode.ONE, q.repeat)
    }

    @Test
    fun `a song the house finishes fetching joins the player, and its progress shows meanwhile`() {
        assertEquals(8, store.playback.exo.mediaItemCount)
        house.events = "event: track_progress\ndata: {\"track_id\":9,\"stage\":\"downloading\",\"percent\":42.0}\n\n"
        var end = System.currentTimeMillis() + 8000
        while (store.fetching.value[9] == null && System.currentTimeMillis() < end) {
            shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(20)
        }
        assertEquals(42f, store.fetching.value[9]?.percent)

        house.nowReady.add(9)
        house.events = "event: track_ready\ndata: {\"track_id\":9}\n\n"
        end = System.currentTimeMillis() + 10000
        while (store.playback.exo.mediaItemCount != 9 && System.currentTimeMillis() < end) {
            shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(50)); Thread.sleep(20)
        }
        assertEquals(house.asked.takeLast(12).joinToString() + " / " + store.playback.now.value.queue?.items?.map { it.state }, 9, store.playback.exo.mediaItemCount)
        assertEquals("i101", store.playback.exo.currentMediaItem?.mediaId)
        assertEquals(null, store.fetching.value[9])
    }

    @Test
    fun `another device hands the music over and this phone plays it from there`() {
        var end = System.currentTimeMillis() + 5000
        while (store.thisDevice == null && System.currentTimeMillis() < end) {
            shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(20)
        }
        assertEquals(2, store.thisDevice)
        house.events = "event: device_command\ndata: {\"to\":2,\"from\":3,\"action\":\"take\",\"queue_id\":2,\"track_id\":5,\"position_ms\":30000}\n\n"
        end = System.currentTimeMillis() + 10000
        while (store.playback.now.value.queue?.id != 2 && System.currentTimeMillis() < end) {
            shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(50)); Thread.sleep(20)
        }
        assertEquals(2, store.playback.now.value.queue?.id)
        assertEquals("The Horse Track", store.playback.now.value.track?.name)
        assertEquals(true, store.playback.exo.playWhenReady)
    }

    @Test
    fun `a kept playlist plays from the phone when the house is gone`() {
        // Robolectric's phone has no network to speak of: downloads are let run anyway.
        store.offline.manager.requirements = androidx.media3.exoplayer.scheduler.Requirements(0)
        store.offline.useService = false
        val p = runBlockingMain { store.api.playlist(2) }
        store.offline.keep("playlist:2", p.name, p.tracks.orEmpty())
        val ready = p.tracks.orEmpty().filter { it.isReady }.map { it.id }.toSet()
        var end = System.currentTimeMillis() + 15000
        while (!store.offline.onPhone.value.containsAll(ready) && System.currentTimeMillis() < end) {
            shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(100)); Thread.sleep(50)
        }
        assertEquals("downloads=" + store.offline.manager.currentDownloads.map { it.request.id + ":" + it.state + ":" + it.failureReason } +
            " init=" + store.offline.manager.isInitialized + " asked=" + house.asked.filter { "stream" in it },
            ready, store.offline.onPhone.value.intersect(ready))

        house.server.close()
        store.api.base = "http://127.0.0.1:1"
        store.play(p.tracks.orEmpty(), 0, p.name)
        end = System.currentTimeMillis() + 15000
        while (store.playback.now.value.queue?.id != -1 && System.currentTimeMillis() < end) {
            shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(100)); Thread.sleep(50)
        }
        assertEquals(-1, store.playback.now.value.queue?.id)
        assertEquals(ready.size, store.playback.exo.mediaItemCount)
    }

    @Test
    fun `a guest follows the host and its buttons ask the host`() {
        house.inJam = true
        runBlockingMain { store.jams.refresh() }
        assertEquals("OWL42", store.jams.jam.value?.code)
        house.events = "event: jam\ndata: {\"jam_id\":5,\"what\":\"playback\",\"track_id\":5,\"item_id\":201,\"position_ms\":42000,\"playing\":true,\"seq\":10}\n\n"
        val end = System.currentTimeMillis() + 10000
        while (store.playback.now.value.track?.id != 5 && System.currentTimeMillis() < end) {
            shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(50)); Thread.sleep(20)
        }
        assertEquals(2, store.playback.now.value.queue?.id)
        assertEquals(5, store.playback.now.value.track?.id)
        assertEquals(true, store.playback.exo.playWhenReady)

        store.playback.next()
        val end2 = System.currentTimeMillis() + 5000
        while (house.asked.none { it == "POST /jams/5/control" } && System.currentTimeMillis() < end2) {
            shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(20)
        }
        assert(house.asked.contains("POST /jams/5/control")) { "next went to the host" }
        assertEquals("the guest's own player did not skip", 5, store.playback.now.value.track?.id)
    }

    private fun <T> runBlockingMain(block: suspend () -> T): T {
        var out: Result<T>? = null
        kotlinx.coroutines.GlobalScope.launch(kotlinx.coroutines.Dispatchers.IO) { out = runCatching { block() } }
        val end = System.currentTimeMillis() + 5000
        while (out == null && System.currentTimeMillis() < end) { shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(20) }
        return out!!.getOrThrow()
    }
}
