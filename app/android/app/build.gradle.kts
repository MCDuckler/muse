import java.util.Properties
import java.io.FileInputStream

// Release signing comes from android/key.properties, which is gitignored. Without it
// the build falls back to debug signing rather than failing, so a fresh checkout still
// produces an installable APK.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.muse.muse"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.muse.muse"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")

            // No shrinking, and above all no renaming of resources.
            //
            // This is the whole of the background-playback bug. Flutter's Gradle plugin
            // turns R8 and resource shrinking on for release builds, and resource
            // shrinking renames every resource — res/drawable/audio_service_play
            // becomes res/-B.png. Anything that looks a resource up by *name* at
            // runtime then gets back id 0, and audio_service does exactly that for the
            // icons on its media controls: every state this app broadcast came back
            //
            //   PlatformException(You must specify an icon resource id to build a
            //   CustomAction)
            //
            // so the Android service never learned anything was playing, never built a
            // notification, never created its channel and never went to the foreground
            // — which leaves the process merely cached, and a cached process is frozen
            // the moment the app leaves the screen. Music stops a few seconds after
            // switching away, and no Dart is running to notice or say so.
            //
            // It also took the launcher icon's own status-bar stencil with it, and it
            // is why a reflective read of the service object came back
            // NoSuchFieldException.
            //
            // Nothing here is worth shrinking for: the APK is sixty megabytes of
            // Flutter engine and assets, and the Java it would strip is a rounding
            // error against that.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // FileProvider, for handing a downloaded APK to the system installer. Flutter's
    // own plugins pull androidx in already, but this module names what it uses rather
    // than relying on somebody else's dependency staying where it is.
    implementation("androidx.core:core-ktx:1.13.1")
}
