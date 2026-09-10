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
