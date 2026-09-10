package dev.muse.muse

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import java.io.File

/**
 * Handing a downloaded APK to the system to install.
 *
 * This is as far as an ordinary app is allowed to go, and it is worth being clear about
 * it: Android will not let anything but a device owner install software without a
 * person saying yes. So the app fetches the new version by itself, checks it is all
 * there, and then asks — one dialog, one tap. What it cannot do is update itself while
 * nobody is looking, and an app claiming otherwise would be lying.
 *
 * The system verifies the signature before it installs anything, which is the check
 * that actually matters: a file that was tampered with on the way down is refused by
 * the installer whatever this app thinks of it.
 */
object Installer {

    /** Whether the user has allowed this app to ask at all. */
    fun mayInstall(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    /** Send them to the one setting that grants it. */
    fun askToAllow(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val intent = Intent(
            android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    /** Open the installer on this file. Returns false if it could not be reached. */
    fun install(context: Context, path: String): Boolean {
        val file = File(path)
        if (!file.exists() || file.length() <= 0) return false
        val uri: Uri = FileProvider.getUriForFile(
            context, "${context.packageName}.files", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (e: Throwable) {
            false
        }
    }
}
