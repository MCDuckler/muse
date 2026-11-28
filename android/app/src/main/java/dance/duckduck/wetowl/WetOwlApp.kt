package dance.duckduck.wetowl

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade

class WetOwlApp : Application(), SingletonImageLoader.Factory {
    lateinit var store: Store
        private set

    override fun onCreate() {
        super.onCreate()
        store = Store(this)
        if (store.user.value != null) store.start()
    }

    /** Covers come from the house and need its sign-in: the same client as everything. */
    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory(callFactory = { store.api.http })) }
            .crossfade(180)
            .build()
}
