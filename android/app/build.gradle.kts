import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release-signing credentials (store blocker fix). Loaded from
// android/key.properties, which is GITIGNORED — the app never holds a
// signing secret in source. When the file is absent (CI, a fresh clone,
// another dev) `keystoreProperties` stays empty and the release build
// falls back to debug signing below, so `flutter run --release` and local
// builds still work without the real keystore.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}
val hasReleaseSigning = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.holdclose.holdclose"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications requires core library desugaring so its
        // java.time usage resolves on minSdk 26 (and older). See
        // https://developer.android.com/studio/write/java8-support.html
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.holdclose.holdclose"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Phase 9.4 — instrumented test for TTSBridge (model load +
        // synth + RMS) runs through AndroidJUnitRunner.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Phase 10.3 — JNI bridge for espeak-ng. ONNX Runtime ships
        // arm64-v8a + x86_64 only on Android; mirror that so the
        // .so set lines up. armeabi-v7a + x86 are intentionally not
        // built — the Piper model performance budget assumes 64-bit.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17")
            }
        }
    }

    // Phase 10.3 — wire the cpp/CMakeLists.txt that compiles
    // libholdclose_espeak_ng.so. On a fresh checkout (no vendor
    // script run yet) CMake still produces the .so — the file(GLOB ...)
    // resolves to an empty source list and the JNI shim's
    // __has_include guards short-circuit. See cpp/README.md.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        // Real release signing, populated only when android/key.properties
        // is present. The store-bound APK/AAB must be signed with the
        // Holdclose release keystore (its SHA-1 is registered on the Google
        // OAuth Android client); a debug-signed release would break Google
        // Sign-In and can't be uploaded to Play.
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                // storeFile is relative to the android/ (root) project dir.
                storeFile = keystoreProperties.getProperty("storeFile")
                    ?.let { rootProject.file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Sign with the real release keystore when key.properties is
            // present (the store build); otherwise fall back to debug keys
            // so `flutter run --release`, CI, and fresh clones still build.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Run R8 with our keep rules (proguard-rules.pro). Even with
            // minify off, core-library desugaring runs R8/D8 and strips the
            // Gson `Signature` attribute that flutter_local_notifications
            // needs — which crashed Android saves (fb 2026-06-14). Enabling
            // minify here makes R8 honor proguard-rules.pro (which keeps the
            // signatures + the TTS/JNI classes) and shrinks the APK.
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // BUILD_SPEC.md Phase 9.4 — ONNX Runtime for the bundled Piper
    // voice (`assets/tts/en_US-amy-medium/`). The NNAPI execution
    // provider routes inference to the device NPU/DSP; older devices
    // fall back to CPU transparently. Mirrors the iOS
    // `onnxruntime-objc` Pod added in Phase 9.3.
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.18.0")

    // Required by flutter_local_notifications' core library desugaring
    // (isCoreLibraryDesugaringEnabled above). Backports java.time etc. to
    // the app's minSdk.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Phase 9.4 — instrumented test wiring for TTSBridge.
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test:runner:1.5.2")
    androidTestImplementation("androidx.test:rules:1.5.0")
}
