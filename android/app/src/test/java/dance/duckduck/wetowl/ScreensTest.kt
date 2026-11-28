package dance.duckduck.wetowl

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.os.Looper
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.hasSetTextAction
import androidx.test.core.app.ApplicationProvider
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.asImage
import coil3.decode.DataSource
import coil3.intercept.Interceptor
import coil3.request.ImageResult
import coil3.request.SuccessResult
import com.github.takahirom.roborazzi.captureRoboImage
import dance.duckduck.wetowl.core.Accent
import dance.duckduck.wetowl.ui.*
import dance.duckduck.wetowl.ui.ArtistScreen
import dance.duckduck.wetowl.ui.Go
import dance.duckduck.wetowl.ui.LocalGo
import dance.duckduck.wetowl.ui.LocalStore
import dance.duckduck.wetowl.ui.LoginScreen
import dance.duckduck.wetowl.ui.NowPlayingScreen
import dance.duckduck.wetowl.ui.PlaylistScreen
import dance.duckduck.wetowl.ui.QueueScreen
import dance.duckduck.wetowl.ui.SettingsScreen
import dance.duckduck.wetowl.ui.theme.WetOwlTheme
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.unit.dp
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.math.abs

/**
 * Every screen drawn against a fake house, at a phone's size, into
 * build/screens/ — the way to look at this app without a phone.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-night-xxhdpi", application = android.app.Application::class)
class ScreensTest {
    @get:Rule val compose = createComposeRule()

    private lateinit var house: FakeHouse
    private lateinit var store: Store

    private val go = object : Go {
        override fun artist(name: String, act: String?) {}
        override fun album(name: String?, artist: String?, remoteId: String?) {}
        override fun playlist(id: Int) {}
        override fun queue() {}
        override fun settings() {}
        override fun back() {}
        override fun web(url: String) {}
        override fun open(route: String) {}
    }

    @Before
    fun setUp() {
        house = FakeHouse()
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.getSharedPreferences("wetowl", Context.MODE_PRIVATE).edit()
            .putString("server", house.base).putString("token", "t").putString("user", "joe")
            .putString("accent", accent.id).commit()
        // Covers drawn rather than fetched: a gradient per address, so each looks its own.
        SingletonImageLoader.setUnsafe(ImageLoader.Builder(context).components { add(FakeCovers) }.build())
        store = Store(context)
    }

    @After
    fun tearDown() {
        store.playback.release()
        store.offline.manager.release()
        store.offline.cache.release()
        house.server.close()
    }

    private val accent = Accent.EMBER

    private object FakeCovers : Interceptor {
        override suspend fun intercept(chain: Interceptor.Chain): ImageResult {
            val key = chain.request.data.toString()
            val h = abs(key.hashCode())
            val bmp = Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888)
            val c = Canvas(bmp)
            val hue = (h % 360).toFloat()
            val a = android.graphics.Color.HSVToColor(floatArrayOf(hue, 0.65f, 0.85f))
            val b = android.graphics.Color.HSVToColor(floatArrayOf((hue + 60) % 360, 0.8f, 0.3f))
            c.drawRect(0f, 0f, 256f, 256f, Paint().apply {
                shader = LinearGradient(0f, 0f, 256f, 256f, a, b, Shader.TileMode.CLAMP)
            })
            c.drawCircle(128f + (h % 60) - 30, 128f, 70f, Paint().apply {
                color = android.graphics.Color.argb(70, 255, 255, 255); isAntiAlias = true
            })
            return SuccessResult(bmp.asImage(), chain.request, DataSource.MEMORY)
        }
    }

    /** Let the fake house answer and the main thread catch up. */
    private fun settle(until: () -> Boolean = { false }, ms: Long = 1500) {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) {
            // The main looper's clock moves only when told: delays (a debounce) need it.
            shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(25))
            compose.mainClock.advanceTimeBy(25)
            compose.waitForIdle()
            if (until()) break
            Thread.sleep(25)
        }
        shadowOf(Looper.getMainLooper()).idle()
        compose.waitForIdle()
    }

    private fun show(content: @Composable () -> Unit) {
        compose.setContent {
            WetOwlTheme(accent) {
                CompositionLocalProvider(LocalStore provides store, LocalGo provides go) {
                    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) { content() }
                }
            }
        }
    }

    private fun shot(name: String) = compose.onRoot().captureRoboImage("build/screens/$name.png")

    private fun startSignedIn() {
        store.start()
        settle(until = { store.playback.now.value.track != null && store.home.value.isNotEmpty() }, ms = 6000)
    }

    @Test fun login() {
        store.signOut()
        show { LoginScreen() }
        settle()
        shot("01-login")
    }

    @Test fun home() {
        startSignedIn()
        show { Shell() }
        settle(ms = 800)
        shot("02-home")
    }

    @Test fun search() {
        startSignedIn()
        show { Shell() }
        settle(ms = 300)
        compose.onNodeWithContentDescription("Search").performClick()
        settle(ms = 300)
        compose.onNode(hasSetTextAction()).performTextInput("fjaak")
        settle(until = { house.asked.any { it.startsWith("GET /search") } }, ms = 3000)
        settle(ms = 600)
        shot("03-search")
    }

    @Test fun library() {
        startSignedIn()
        show { Shell() }
        settle(ms = 300)
        compose.onNodeWithContentDescription("Library").performClick()
        settle(ms = 1200)
        shot("04-library")
    }

    @Test fun playlist() {
        startSignedIn()
        show { PlaylistScreen(2, PaddingValues(bottom = 24.dp)) }
        settle(ms = 1500)
        shot("05-playlist")
    }

    @Test fun artist() {
        startSignedIn()
        show { ArtistScreen("Maara", null, PaddingValues(bottom = 24.dp)) }
        settle(ms = 1500)
        shot("06-artist")
    }

    @Test fun album() {
        startSignedIn()
        show { AlbumScreen("Concrete Bloom", "Hollow Sun", null, PaddingValues(bottom = 24.dp)) }
        settle(ms = 1500)
        shot("07-album")
    }

    @Test fun nowPlaying() {
        startSignedIn()
        show { NowPlayingScreen(onClose = {}, onQueue = {}) }
        settle(ms = 1000)
        shot("08-now-playing")
    }

    @Test fun queue() {
        startSignedIn()
        show { QueueScreen(overlay = 24.dp) }
        settle(ms = 1200)
        shot("09-queue")
    }

    @Test fun queuePreview() {
        startSignedIn()
        show { QueueScreen(overlay = 24.dp) }
        settle(ms = 800)
        compose.onNodeWithText("Gym · 3").performClick()
        settle(until = { house.asked.contains("GET /queues/2") }, ms = 3000)
        settle(ms = 600)
        shot("10-queue-preview")
        // Looking is not playing.
        check(store.playback.now.value.queue?.id == 1) { "looking at Gym must not put it on" }
    }

    @Test fun settings() {
        startSignedIn()
        show { SettingsScreen(PaddingValues(bottom = 24.dp)) }
        settle(ms = 500)
        shot("11-settings")
    }

    @Test fun stats() {
        startSignedIn()
        show { StatsScreen(PaddingValues(bottom = 24.dp)) }
        settle(until = { house.asked.any { it.startsWith("GET /library/stats") } }, ms = 3000)
        settle(ms = 600)
        shot("12-stats")
    }

    @Test fun history() {
        startSignedIn()
        show { HistoryScreen(PaddingValues(bottom = 24.dp)) }
        settle(ms = 1200)
        shot("13-history")
    }

    @Test fun folder() {
        startSignedIn()
        show { FolderScreen(7, PaddingValues(bottom = 24.dp)) }
        settle(ms = 1200)
        shot("14-folder")
    }

    @Test fun playlistMenu() {
        startSignedIn()
        show { PlaylistScreen(2, PaddingValues(bottom = 24.dp)) }
        settle(ms = 1200)
        compose.onNodeWithContentDescription("Playlist options").performClick()
        settle(ms = 800)
        shot("15-playlist-menu")
    }

    @Test fun discover() {
        startSignedIn()
        show { DiscoverScreen(PaddingValues(bottom = 24.dp)) }
        settle(until = { house.asked.any { it.startsWith("GET /discover") } }, ms = 3000)
        settle(ms = 800)
        shot("16-discover")
    }

    @Test fun nowPlayingWords() {
        startSignedIn()
        show { NowPlayingScreen(onClose = {}, onQueue = {}) }
        settle(ms = 600)
        compose.onNodeWithContentDescription("Words").performClick()
        settle(ms = 1200)
        shot("17-words")
    }

    @Test fun devices() {
        startSignedIn()
        show { DevicesSheet {} }
        settle(until = { store.devices.value.isNotEmpty() }, ms = 3000)
        settle(ms = 800)
        shot("18-devices")
    }

    @Test fun sleeve() {
        startSignedIn()
        show { NowPlayingScreen(onClose = {}, onQueue = {}) }
        settle(ms = 600)
        compose.onNodeWithContentDescription("Draw on the sleeve").performClick()
        settle(until = { house.asked.any { it.endsWith("/marks") } }, ms = 3000)
        settle(ms = 600)
        shot("19-sleeve")
    }

    @Test fun cards() {
        startSignedIn()
        show { CardsScreen(PaddingValues(bottom = 24.dp)) }
        settle(until = { house.asked.any { it.startsWith("GET /discover/cards/") } }, ms = 4000)
        settle(ms = 800)
        shot("20-cards")
    }
}
