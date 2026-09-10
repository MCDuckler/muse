package dev.muse.muse

import android.webkit.CookieManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
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
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
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
