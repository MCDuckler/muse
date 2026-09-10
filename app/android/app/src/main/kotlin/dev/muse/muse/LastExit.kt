package dev.muse.muse

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build

/**
 * Why this app stopped running last time.
 *
 * "The music stops when I leave the app" has been chased three times now, and every
 * answer so far has been a guess dressed as a diagnosis, because the interesting minute
 * is always the one with the screen off and nothing watching. Android has kept the
 * answer the whole time: it writes down why it killed a process and hands the record
 * back on request.
 *
 * This is the difference between "something stopped it" and "the system reclaimed it for
 * memory" or "it crashed" or "a task killer force-stopped it" — three faults with three
 * completely different fixes, only one of which is ours.
 */
object LastExit {

    /** A sentence about how the app died last time, or nothing if it did not. */
    fun describe(context: Context): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return null
        val info = try {
            am.getHistoricalProcessExitReasons(null, 0, 1).firstOrNull()
        } catch (e: Throwable) {
            null
        } ?: return null

        val why = when (info.reason) {
            ApplicationExitInfo.REASON_LOW_MEMORY ->
                "the system needed the memory"
            ApplicationExitInfo.REASON_CRASH -> "it crashed"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "it crashed (native)"
            ApplicationExitInfo.REASON_ANR -> "it stopped responding"
            ApplicationExitInfo.REASON_USER_REQUESTED ->
                "somebody force-stopped it"
            ApplicationExitInfo.REASON_USER_STOPPED -> "the user stopped it"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE ->
                "it was using too much of something"
            ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "something it needed died"
            ApplicationExitInfo.REASON_OTHER -> "the system killed it"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "it failed to start"
            ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "a permission changed"
            ApplicationExitInfo.REASON_EXIT_SELF -> "it exited on its own"
            ApplicationExitInfo.REASON_SIGNALED -> "it was signalled"
            else -> "reason ${info.reason}"
        }
        // Importance says whether the system thought it was in the foreground, playing
        // in the background, or already cached — which is most of whether the
        // foreground service was doing its job.
        val standing = when (info.importance) {
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "in front"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE ->
                "playing in the background"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "a service"
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> "cached"
            else -> "importance ${info.importance}"
        }
        val note = info.description?.takeIf { it.isNotBlank() }?.let { " — $it" } ?: ""
        val mb = info.pss / 1024
        return "last run ended: $why (it was $standing, ${mb}MB)$note"
    }
}
