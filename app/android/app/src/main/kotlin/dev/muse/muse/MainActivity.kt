package dev.muse.muse

import android.webkit.CookieManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity, not FlutterActivity: audio_service routes lockscreen and
// headset-button events through it. With a plain FlutterActivity the notification
// appears but its buttons do nothing.
class MainActivity : AudioServiceActivity() {

    /// Reading the browser's own cookie jar.
    ///
    /// Signing in to YouTube Music happens in a WebView, and what the server needs
    /// afterwards is the cookie that sign-in produced. The obvious way — asking the
    /// page for `document.cookie` — cannot see the ones marked HttpOnly, which is most
    /// of the ones that matter. The platform's CookieManager can, and it is four lines,
    /// which is a better trade than a plugin that has not been updated for this
    /// version of the Android build tools.
    private var spectrum: Spectrum? = null

    /**
     * Asking to be allowed to show the playing notification.
     *
     * Declared in the manifest since the beginning and never once requested, and since
     * Android 13 declaring it is not enough — notifications are off until an app asks.
     * No notification is no media session anybody can see, and a process without a
     * foreground service is a cached one, which the system may freeze the moment the
     * app leaves the screen. That is the app going quiet a few seconds after being
     * switched away from, and the system's own record of every kill agreeing it was
     * "cached" at the time.
     */
    private fun askForNotifications() {
        if (android.os.Build.VERSION.SDK_INT < 33) return
        val granted = androidx.core.content.ContextCompat.checkSelfPermission(
            this, "android.permission.POST_NOTIFICATIONS"
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (granted) return
        androidx.core.app.ActivityCompat.requestPermissions(
            this, arrayOf("android.permission.POST_NOTIFICATIONS"), 7301)
    }

    /** Whether the system will actually let this app put a notification up. */
    private fun mayNotify(): Boolean =
        androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled()

    /**
     * The app's own notification settings, opened for somebody to turn them back on.
     *
     * Once the permission has been refused, asking again does nothing at all — Android
     * takes the second refusal as final and the dialog never appears again. From then
     * on the only way back is this page, so the app has to be able to offer it.
     */
    private fun openNotificationSettings() {
        val intent = android.content.Intent(
            android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS
        ).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
        try {
            startActivity(intent)
        } catch (e: Throwable) {
            startActivity(
                android.content.Intent(
                    android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    android.net.Uri.fromParts("package", packageName, null)))
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, results: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, results)
        spectrum?.onPermissionAnswer(
            requestCode,
            results.isNotEmpty() && results[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
        )
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)

        // The bars under the artwork. See Spectrum for why this needs the microphone
        // permission to read the app's own output.
        val bars = Spectrum(this)
        spectrum = bars
        EventChannel(engine.dartExecutor.binaryMessenger, "muse/spectrum")
            .setStreamHandler(bars)
        MethodChannel(engine.dartExecutor.binaryMessenger, "muse/spectrum/permission")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "has" -> result.success(bars.hasPermission())
                    "ask" -> bars.askForPermission(result)
                    else -> result.notImplemented()
                }
            }
        // See Keepalive: the radio has to stay up for a stream to keep arriving once
        // the screen is off.
        // Fetching a new version and asking to install it. See Installer.
        MethodChannel(engine.dartExecutor.binaryMessenger, "muse/install")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "allowed" -> result.success(Installer.mayInstall(applicationContext))
                    "allow" -> {
                        Installer.askToAllow(this)
                        result.success(null)
                    }
                    "open" -> result.success(
                        Installer.install(applicationContext,
                            call.argument<String>("path") ?: ""))
                    else -> result.notImplemented()
                }
            }
        // Asked once, the first time something plays — not at launch, where it is a
        // permission prompt in front of somebody who has not yet seen the app.
        MethodChannel(engine.dartExecutor.binaryMessenger, "muse/notify")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ask" -> {
                        askForNotifications()
                        result.success(null)
                    }
                    "allowed" -> result.success(mayNotify())
                    "settings" -> {
                        openNotificationSettings()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // Whether the foreground service is actually there. See Health.
        MethodChannel(engine.dartExecutor.binaryMessenger, "muse/health")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "describe" -> result.success(Health.describe(applicationContext))
                    else -> result.notImplemented()
                }
            }
        // Why the app stopped running last time. See LastExit.
        MethodChannel(engine.dartExecutor.binaryMessenger, "muse/lastexit")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "describe" -> result.success(LastExit.describe(applicationContext))
                    else -> result.notImplemented()
                }
            }
        MethodChannel(engine.dartExecutor.binaryMessenger, "muse/keepalive")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "set" -> {
                        Keepalive.set(applicationContext, call.argument<Boolean>("on") == true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(engine.dartExecutor.binaryMessenger, "muse/cookies")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "get" -> {
                        val url = call.argument<String>("url")
                        result.success(CookieManager.getInstance().getCookie(url))
                    }
                    "clear" -> {
                        CookieManager.getInstance().removeAllCookies(null)
                        CookieManager.getInstance().flush()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
