package dance.duckduck.wetowl

import dance.duckduck.wetowl.ui.theme.*
import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import dance.duckduck.wetowl.player.PlaybackService
import dance.duckduck.wetowl.ui.*
import dance.duckduck.wetowl.ui.ArtistScreen
import dance.duckduck.wetowl.ui.Go
import dance.duckduck.wetowl.ui.HomeScreen
import dance.duckduck.wetowl.ui.LibraryScreen
import dance.duckduck.wetowl.ui.LocalGo
import dance.duckduck.wetowl.ui.LocalStore
import dance.duckduck.wetowl.ui.LoginScreen
import dance.duckduck.wetowl.ui.MiniPlayer
import dance.duckduck.wetowl.ui.NowPlayingScreen
import dance.duckduck.wetowl.ui.PlaylistScreen
import dance.duckduck.wetowl.ui.QueueScreen
import dance.duckduck.wetowl.ui.SearchScreen
import dance.duckduck.wetowl.ui.SettingsScreen
import dance.duckduck.wetowl.ui.theme.WetOwlTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private var controller: com.google.common.util.concurrent.ListenableFuture<MediaController>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        val store = (application as WetOwlApp).store
        takeShare(intent)
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        setContent {
            val accent by store.prefs.accent.collectAsState()
            WetOwlTheme(accent) {
                CompositionLocalProvider(LocalStore provides store) { Root() }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        takeShare(intent)
    }

    private fun takeShare(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()?.takeIf { it.isNotEmpty() } ?: return
        (application as WetOwlApp).store.shared.tryEmit(text)
    }

    override fun onStart() {
        super.onStart()
        // Connecting is what starts the service: from then on the music has a
        // notification and keeps playing with the app in the background.
        controller = MediaController.Builder(this, SessionToken(this, ComponentName(this, PlaybackService::class.java)))
            .buildAsync()
        (application as WetOwlApp).store.playback.refresh()
    }

    override fun onStop() {
        controller?.let { MediaController.releaseFuture(it) }
        controller = null
        super.onStop()
    }
}

private enum class Tab(val route: String, val label: String, val icon: ImageVector) {
    HOME("home", "Home", Icons.Rounded.Home),
    DISCOVER("discover", "Discover", Icons.Rounded.Explore),
    SEARCH("search", "Search", Icons.Rounded.Search),
    LIBRARY("library", "Library", Icons.Rounded.LibraryMusic),
}

@Composable
internal fun Root() {
    val store = LocalStore.current
    val user by store.user.collectAsState()
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        if (user == null) LoginScreen() else Shell()
    }
}

@Composable
internal fun Shell() {
    val store = LocalStore.current
    val nav = rememberNavController()
    val context = androidx.compose.ui.platform.LocalContext.current
    var playerOpen by rememberSaveable { mutableStateOf(false) }
    val now by store.playback.now.collectAsState()
    val snacks = remember { SnackbarHostState() }
    LaunchedEffect(Unit) { store.playback.notes.collect { snacks.showSnackbar(it) } }
    LaunchedEffect(Unit) { store.reactions.collect { (who, emoji) -> snacks.showSnackbar("$emoji  $who likes what you are playing") } }

    val go = remember(nav) {
        object : Go {
            override fun artist(name: String, act: String?) =
                nav.navigate("artist?name=${Uri.encode(name)}" + (act?.let { "&act=${Uri.encode(it)}" } ?: ""))
            override fun album(name: String?, artist: String?, remoteId: String?) =
                nav.navigate("album?name=${Uri.encode(name ?: "")}&artist=${Uri.encode(artist ?: "")}&rid=${Uri.encode(remoteId ?: "")}")
            override fun playlist(id: Int) = nav.navigate("playlist/$id")
            override fun queue() { playerOpen = false; nav.navigate("queue") { launchSingleTop = true } }
            override fun settings() = nav.navigate("settings") { launchSingleTop = true }
            override fun back() { nav.popBackStack() }
            override fun open(route: String) = nav.navigate(route) { launchSingleTop = true }
            override fun web(url: String) {
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            }
        }
    }

    LaunchedEffect(Unit) { store.shared.collect { text -> store.shared.resetReplayCache(); openShared(store, go, text) } }
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route ?: "home"
    val hasPlayer = now.track != null
    val navInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // What floats over the bottom of every page: the tab bar, and the mini player on it.
    val overlay = navInset + 76.dp + (if (hasPlayer) 78.dp else 0.dp)
    val bottom = PaddingValues(bottom = overlay + 8.dp)

    CompositionLocalProvider(LocalGo provides go) {
        Box(Modifier.fillMaxSize()) {
            NavHost(nav, startDestination = "home", modifier = Modifier.fillMaxSize()) {
                composable("home") { HomeScreen(bottom) }
                composable("search?q={q}", listOf(navArgument("q") { type = NavType.StringType; defaultValue = "" })) {
                    SearchScreen(bottom, it.arguments?.getString("q") ?: "")
                }
                composable("library") { LibraryScreen(bottom) }
                composable("settings") { SettingsScreen(bottom) }
                composable("queue") { QueueScreen(overlay) }
                composable("playlist/{id}", listOf(navArgument("id") { type = NavType.IntType })) {
                    PlaylistScreen(it.arguments?.getInt("id") ?: 0, bottom)
                }
                composable("folder/{id}", listOf(navArgument("id") { type = NavType.IntType })) {
                    FolderScreen(it.arguments?.getInt("id") ?: 0, bottom)
                }
                composable("smart/{id}") { SmartListScreen(it.arguments?.getString("id") ?: "", bottom) }
                composable("history") { HistoryScreen(bottom) }
                composable("similar/{id}?title={title}", listOf(
                    navArgument("id") { type = NavType.IntType },
                    navArgument("title") { type = NavType.StringType; defaultValue = "" },
                )) { SimilarScreen(it.arguments?.getInt("id") ?: 0, it.arguments?.getString("title") ?: "", bottom) }
                composable("discover") { DiscoverScreen(bottom) }
                composable("cards") { CardsScreen(bottom) }
                composable("equalizer") { EqualizerScreen(bottom) }
                composable("playback-log") { PlaybackLogScreen(bottom) }
                composable("downloads") { HouseDownloadsScreen(bottom) }
                composable("offline") { OfflineScreen(bottom) }
                composable("people") { PeopleScreen(bottom) }
                composable("services") { ServicesScreen(bottom) }
                composable("accounts") { AccountsScreen(bottom) }
                composable("service/{provider}") { ServicePlaylistsScreen(it.arguments?.getString("provider") ?: "", bottom) }
                composable("unmatched/{id}", listOf(navArgument("id") { type = NavType.IntType })) {
                    UnmatchedScreen(it.arguments?.getInt("id") ?: 0, bottom)
                }
                composable("person/{id}", listOf(navArgument("id") { type = NavType.IntType })) {
                    PersonScreen(it.arguments?.getInt("id") ?: 0, bottom)
                }
                composable("made/{slug}") { MadeListScreen(it.arguments?.getString("slug") ?: "", bottom) }
                composable("genres") { GenresScreen(bottom) }
                composable("follows") { FollowsScreen(bottom) }
                composable("bandcamp?url={url}&name={name}", listOf(
                    navArgument("url") { type = NavType.StringType; defaultValue = "" },
                    navArgument("name") { type = NavType.StringType; defaultValue = "" },
                )) { BandcampBandScreen(it.arguments?.getString("url") ?: "", it.arguments?.getString("name") ?: "", bottom) }
                composable("bandcamp-record?url={url}", listOf(
                    navArgument("url") { type = NavType.StringType; defaultValue = "" },
                )) { BandcampRecordScreen(it.arguments?.getString("url") ?: "", bottom) }
                composable("found-album?place={place}&id={id}", listOf(
                    navArgument("place") { type = NavType.StringType; defaultValue = "" },
                    navArgument("id") { type = NavType.StringType; defaultValue = "" },
                )) { FoundAlbumScreen(it.arguments?.getString("place") ?: "", it.arguments?.getString("id") ?: "", bottom) }
                composable("stats") { StatsScreen(bottom) }
                composable("notforme") { NotForMeScreen(bottom) }
                composable("artist?name={name}&act={act}", listOf(
                    navArgument("name") { type = NavType.StringType; defaultValue = "" },
                    navArgument("act") { type = NavType.StringType; nullable = true; defaultValue = null },
                )) {
                    Box {
                        ArtistScreen(it.arguments?.getString("name") ?: "", it.arguments?.getString("act"), bottom)
                        FloatingTop()
                    }
                }
                composable("album?name={name}&artist={artist}&rid={rid}", listOf(
                    navArgument("name") { type = NavType.StringType; defaultValue = "" },
                    navArgument("artist") { type = NavType.StringType; defaultValue = "" },
                    navArgument("rid") { type = NavType.StringType; defaultValue = "" },
                )) {
                    val a = it.arguments
                    Box {
                        AlbumScreen(a?.getString("name")?.ifEmpty { null }, a?.getString("artist")?.ifEmpty { null },
                            a?.getString("rid")?.ifEmpty { null }, bottom)
                        FloatingTop()
                    }
                }
            }

            // The bottom: a fade so lists slide under softly, the mini player, the tabs.
            Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth()) {
                Box(Modifier.fillMaxWidth().height(28.dp).background(Brush.verticalGradient(
                    listOf(Color.Transparent, MaterialTheme.colorScheme.background))))
                Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background).navigationBarsPadding()) {
                    val picking = store.selection.collectAsState().value.isNotEmpty()
                    if (picking) SelectionBar()
                    else if (hasPlayer) MiniPlayer(onOpen = { playerOpen = true }, modifier = Modifier.padding(bottom = 10.dp))
                    TabBar(route) { tab ->
                        nav.navigate(tab.route) {
                            popUpTo("home") { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    }
                }
            }

            val reachable by store.events.reachable.collectAsState()
            AnimatedVisibility(!reachable, modifier = Modifier.align(Alignment.TopCenter),
                enter = slideInVertically { -it } + fadeIn(), exit = slideOutVertically { -it } + fadeOut()) {
                Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.errorContainer).statusBarsPadding()
                    .clickable { go.open("offline") }.padding(horizontal = 18.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text("Can't reach the house — what is kept on the phone still plays",
                        style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onErrorContainer)
                }
            }

            SnackbarHost(snacks, Modifier.align(Alignment.BottomCenter).padding(bottom = overlay + 8.dp))

            AnimatedVisibility(
                playerOpen && hasPlayer,
                enter = slideInVertically(tween(320)) { it } + fadeIn(),
                exit = slideOutVertically(tween(260)) { it } + fadeOut(),
            ) {
                BackHandler { playerOpen = false }
                Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
                    NowPlayingScreen(onClose = { playerOpen = false }, onQueue = { go.queue() })
                }
            }
        }
    }
}

/** Three tabs, the chosen one a lit well pressed into a raised bar. */
@Composable
private fun TabBar(route: String, onTab: (Tab) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 8.dp).height(64.dp)
            .tonal(corner = 24.dp).padding(7.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        for (tab in Tab.entries) {
            val on = route.startsWith(tab.route)
            Box(
                Modifier.weight(if (on) 1.7f else 1f).fillMaxWidth().height(50.dp)
                    .then(if (on) Modifier.picked(corner = 18.dp) else Modifier)
                    .clip(RoundedCornerShape(18.dp))
                    .clickable { onTab(tab) },
                contentAlignment = Alignment.Center,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(tab.icon, tab.label, tint = if (on) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(22.dp))
                    if (on) {
                        Spacer(Modifier.size(6.dp))
                        Text(tab.label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                    }
                }
            }
        }
    }
}


private val YT = Regex("""(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/)|youtu\.be/)([A-Za-z0-9_-]{11})""")

/** Something shared into the app: a YouTube link plays, a Bandcamp page opens, anything else is searched for. */
internal fun openShared(store: Store, go: Go, text: String) {
    val url = Regex("""https?://\S+""").find(text)?.value
    val yt = url?.let { YT.find(it)?.groupValues?.get(1) }
    when {
        yt != null -> store.launch {
            val t = store.api.resolve(dance.duckduck.wetowl.core.RemoteHit(yt, text.substringBefore("http").trim()
                .ifBlank { "Shared from YouTube" }, emptyList(), null, null, null))
            store.play(listOf(t), 0, "Shared")
            store.playback.notes.tryEmit("Fetching what was shared — it plays as soon as it is here")
        }
        url != null && "bandcamp.com" in url && ("/album/" in url || "/track/" in url) ->
            go.open("bandcamp-record?url=${Uri.encode(url)}")
        url != null && "bandcamp.com" in url -> go.open("bandcamp?url=${Uri.encode(url)}&name=")
        else -> go.open("search?q=${Uri.encode(url ?: text)}")
    }
}
