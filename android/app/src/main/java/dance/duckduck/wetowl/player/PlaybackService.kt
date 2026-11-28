@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package dance.duckduck.wetowl.player

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.session.CacheBitmapLoader
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import dance.duckduck.wetowl.MainActivity
import dance.duckduck.wetowl.Store
import dance.duckduck.wetowl.WetOwlApp
import dance.duckduck.wetowl.core.madeList
import dance.duckduck.wetowl.core.discover
import dance.duckduck.wetowl.core.trackCover
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The music's place in the system: the notification, the lock screen, headphones'
 * buttons, Bluetooth — and Android Auto, which browses it as a library: your queues,
 * your playlists, the lists made for you, what is kept on the phone. It wraps the
 * process's one player; the app's screens use the same player directly.
 */
class PlaybackService : MediaLibraryService() {
    private var session: MediaLibrarySession? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val store: Store get() = (application as WetOwlApp).store

    override fun onCreate() {
        super.onCreate()
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // What a car (or any other browser) asks to play is one of ours by id: it is put
        // on the house's way — into a queue — rather than laid straight onto the player.
        val player = object : ForwardingPlayer(store.playback.exo) {
            override fun setMediaItems(items: MutableList<MediaItem>, startIndex: Int, startPositionMs: Long) {
                if (items.firstOrNull()?.mediaId?.startsWith("wo:") == true) playId(items[startIndex.coerceIn(0, items.size - 1)].mediaId)
                else super.setMediaItems(items, startIndex, startPositionMs)
            }
            override fun setMediaItems(items: MutableList<MediaItem>, resetPosition: Boolean) =
                setMediaItems(items, 0, 0)
            override fun setMediaItem(item: MediaItem) = setMediaItems(mutableListOf(item), 0, 0)
            override fun setMediaItem(item: MediaItem, startPositionMs: Long) = setMediaItems(mutableListOf(item), 0, startPositionMs)
            override fun setMediaItem(item: MediaItem, resetPosition: Boolean) = setMediaItems(mutableListOf(item), 0, 0)
            override fun seekToNext() { store.playback.next() }
            override fun seekToPrevious() { store.playback.previous() }
        }
        session = MediaLibrarySession.Builder(this, player, Library())
            .setSessionActivity(open)
            // Covers are behind the house's sign-in: fetched with the same client.
            .setBitmapLoader(CacheBitmapLoader(
                DataSourceBitmapLoader.Builder(this)
                    .setDataSourceFactory(OkHttpDataSource.Factory(store.api.http))
                    .build()))
            .build()
    }

    private fun playId(id: String) {
        val parts = id.removePrefix("wo:").split(":", limit = 3)
        scope.launch {
            runCatching {
                when (parts[0]) {
                    "queue" -> store.playback.open(parts[1].toInt())
                    "playlist" -> {
                        val p = store.api.playlist(parts[1].toInt())
                        val tracks = p.tracks.orEmpty()
                        store.play(tracks, parts.getOrNull(2)?.toIntOrNull()?.coerceAtLeast(0) ?: 0, p.shownName)
                    }
                    "made" -> { val l = store.api.madeList(Uri.decode(parts[1])); store.play(l.tracks, 0, l.name) }
                    "kept" -> {
                        val k = store.offline.kept.value.firstOrNull { it.key == Uri.decode(parts[1]) } ?: return@runCatching
                        store.play(k.tracks, 0, k.name)
                    }
                }
            }
        }
    }

    private fun folder(id: String, title: String, sub: String? = null) = MediaItem.Builder().setMediaId(id)
        .setMediaMetadata(MediaMetadata.Builder().setTitle(title).setSubtitle(sub).setIsBrowsable(true).setIsPlayable(false)
            .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_MIXED).build()).build()

    private fun playable(id: String, title: String, sub: String?, art: String?, browsable: Boolean = false) = MediaItem.Builder()
        .setMediaId(id)
        .setMediaMetadata(MediaMetadata.Builder().setTitle(title).setSubtitle(sub).setArtist(sub)
            .setArtworkUri(art?.let(Uri::parse)).setIsBrowsable(browsable).setIsPlayable(true)
            .setMediaType(if (browsable) MediaMetadata.MEDIA_TYPE_PLAYLIST else MediaMetadata.MEDIA_TYPE_MUSIC).build())
        .build()

    private inner class Library : MediaLibrarySession.Callback {
        override fun onGetLibraryRoot(session: MediaLibrarySession, browser: MediaSession.ControllerInfo,
                                      params: LibraryParams?): ListenableFuture<LibraryResult<MediaItem>> =
            Futures.immediateFuture(LibraryResult.ofItem(folder("root", "WetOwl"), params))

        override fun onGetItem(session: MediaLibrarySession, browser: MediaSession.ControllerInfo,
                               mediaId: String): ListenableFuture<LibraryResult<MediaItem>> =
            Futures.immediateFuture(LibraryResult.ofItem(playable(mediaId, mediaId, null, null), null))

        override fun onGetChildren(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, parentId: String,
                                   page: Int, pageSize: Int, params: LibraryParams?): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
            val out = SettableFuture.create<LibraryResult<ImmutableList<MediaItem>>>()
            scope.launch {
                val items: List<MediaItem> = runCatching {
                    when {
                        parentId == "root" -> listOf(folder("queues", "Queues"), folder("playlists", "Playlists"),
                            folder("made", "Made for you"), folder("phone", "On this phone"))
                        parentId == "queues" -> { store.refreshQueues(); store.queues.value.map { q ->
                            playable("wo:queue:${q.id}", q.sharedFrom?.let { "$it's jam" } ?: q.name, "${q.total} songs", null) } }
                        parentId == "playlists" -> { store.refreshPlaylists(); store.playlists.value.map { p ->
                            folder("pl:${p.id}", p.shownName, "${p.count} songs") } }
                        parentId.startsWith("pl:") -> {
                            val p = store.api.playlist(parentId.removePrefix("pl:").toInt())
                            p.tracks.orEmpty().mapIndexed { i, t ->
                                playable("wo:playlist:${p.id}:$i", t.name, t.artistLine, store.api.coverUrl(t, small = false))
                            }
                        }
                        parentId == "made" -> store.api.discover().lists.map { l ->
                            playable("wo:made:${Uri.encode(l.slug)}", l.name, l.blurb.ifBlank { "${l.count} songs" },
                                l.tracks.firstOrNull()?.let { store.api.coverUrl(it, small = false) })
                        }
                        parentId == "phone" -> store.offline.kept.value.map { k ->
                            playable("wo:kept:${Uri.encode(k.key)}", k.name, "${k.tracks.size} songs",
                                k.tracks.firstOrNull()?.let { store.api.coverUrl(it, small = false) })
                        }
                        else -> emptyList()
                    }
                }.getOrDefault(emptyList())
                out.set(LibraryResult.ofItemList(ImmutableList.copyOf(items), params))
            }
            return out
        }

        // What a browser picked is handed back as it is; the player above knows what it means.
        override fun onAddMediaItems(session: MediaSession, controller: MediaSession.ControllerInfo,
                                     items: MutableList<MediaItem>): ListenableFuture<MutableList<MediaItem>> =
            Futures.immediateFuture(items)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? = session

    /** Swiped away from recents while nothing plays: nothing to keep running for. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = session?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        session?.run {
            // The player belongs to the process, not to the service.
            release()
        }
        session = null
        super.onDestroy()
    }
}
