package dev.muse.muse

import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.os.Build

/**
 * Whether the things that keep music playing in the background are actually there.
 *
 * Audio stopping after the app is switched away from has been chased five times now,
 * and every fix has been aimed at a mechanism nobody had confirmed was involved. The
 * system's record of the last few kills says the app was *cached* at the time — which,
 * if the foreground service were running, it could not have been. That is a claim worth
 * checking directly rather than reasoning about, because it decides everything: a
 * service that is not running explains the whole thing, and a service that is running
 * means the fault is somewhere else entirely and five rounds of guessing at this one
 * have been wasted.
 */
object Health {

    /** A sentence about whether the media notification — and so the service — is up. */
    fun describe(context: Context): String {
        val parts = mutableListOf<String>()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as? NotificationManager
        if (nm == null) {
            parts += "no notification manager"
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val ours = try {
                nm.activeNotifications.toList()
            } catch (e: Throwable) {
                emptyList()
            }
            parts += if (ours.isEmpty()) {
                "no notification — nothing is holding this app in the foreground"
            } else {
                "notification up (${ours.joinToString { it.notification.channelId }})"
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = nm.getNotificationChannel("dev.muse.audio")
                parts += when {
                    channel == null -> "channel missing"
                    channel.importance == NotificationManager.IMPORTANCE_NONE ->
                        "channel blocked"
                    else -> "channel ok"
                }
                // And every channel the app actually has.
                //
                // "channel missing" only says the one this app asked for is not there.
                // It cannot tell a media service that never started from one that
                // started and made its channel under a different name, and those are
                // two different faults — so list what is really there.
                val all = try {
                    nm.notificationChannels.map { it.id }
                } catch (e: Throwable) {
                    emptyList()
                }
                parts += if (all.isEmpty()) "no channels at all"
                         else "channels: " + all.joinToString()
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                if (!nm.areNotificationsEnabled()) parts += "NOTIFICATIONS ARE OFF"
            }
        }

        // What the system thinks this process is worth right now. A process running a
        // foreground service cannot be "cached"; one that is cached can be frozen the
        // moment it leaves the screen, and a frozen app makes no sound and cannot say
        // so either.
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        if (am != null) {
            val state = ActivityManager.RunningAppProcessInfo()
            ActivityManager.getMyMemoryState(state)
            parts += "standing: " + when (state.importance) {
                ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "in front"
                ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE ->
                    "foreground service"
                ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "visible"
                ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "service"
                ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> "cached"
                else -> "importance ${state.importance}"
            }
        }
        // Whether the media service is actually there. getRunningServices only ever
        // reports an app's own services now, which is exactly the question: is the
        // thing that is supposed to be holding this process up running at all.
        if (am != null) {
            val ours = try {
                @Suppress("DEPRECATION")
                am.getRunningServices(64).filter {
                    it.service.packageName == context.packageName
                }
            } catch (e: Throwable) {
                emptyList()
            }
            parts += if (ours.isEmpty()) {
                "no service of ours is running"
            } else {
                "services: " + ours.joinToString {
                    it.service.className.substringAfterLast('.') +
                        (if (it.foreground) " (foreground)" else " (background)")
                }
            }
        }
        if (Build.VERSION.SDK_INT >= 33) {
            val asked = androidx.core.content.ContextCompat.checkSelfPermission(
                context, "android.permission.POST_NOTIFICATIONS"
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            parts += if (asked) "may post notifications" else "NOT ALLOWED TO NOTIFY"
        }
        parts += "android ${Build.VERSION.SDK_INT}"
        return parts.joinToString(" · ")
    }
}
