@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package dance.duckduck.wetowl.player

import android.app.Notification
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadNotificationHelper
import androidx.media3.exoplayer.offline.DownloadService
import androidx.media3.exoplayer.scheduler.Scheduler
import dance.duckduck.wetowl.R
import dance.duckduck.wetowl.WetOwlApp

/** Keeps songs downloading onto the phone with the app in the background, with a notification saying so. */
class OfflineService : DownloadService(7, DEFAULT_FOREGROUND_NOTIFICATION_UPDATE_INTERVAL, CHANNEL, R.string.offline_channel, 0) {
    override fun getDownloadManager(): DownloadManager = (application as WetOwlApp).store.offline.manager

    override fun getScheduler(): Scheduler? = null

    override fun getForegroundNotification(downloads: MutableList<Download>, notMetRequirements: Int): Notification =
        DownloadNotificationHelper(this, CHANNEL).buildProgressNotification(
            this, R.drawable.ic_notification, null,
            "Keeping ${downloads.size} songs on this phone", downloads, notMetRequirements)

    companion object { const val CHANNEL = "offline" }
}
