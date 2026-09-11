plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "de.seifert.castqueue"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "de.seifert.castqueue"
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

    // Release signing comes from the environment (CI decodes the keystore
    // from a secret). Without CASTQUEUE_STORE_FILE the release build falls
    // back to the debug key so a local `flutter build apk` keeps working;
    // CASTQUEUE_REQUIRE_SIGNING=1 turns a missing keystore into a build error.
    val releaseKeystorePath = System.getenv("CASTQUEUE_STORE_FILE")
    val signingRequired = System.getenv("CASTQUEUE_REQUIRE_SIGNING") == "1"

    signingConfigs {
        create("release") {
            if (!releaseKeystorePath.isNullOrBlank()) {
                storeFile = file(releaseKeystorePath)
                storePassword = System.getenv("CASTQUEUE_STORE_PASSWORD")
                keyAlias = System.getenv("CASTQUEUE_KEY_ALIAS")
                keyPassword = System.getenv("CASTQUEUE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            require(!signingRequired || !releaseKeystorePath.isNullOrBlank()) {
                "CASTQUEUE_STORE_FILE is required for a signed release build"
            }
            signingConfig = if (releaseKeystorePath.isNullOrBlank()) {
                signingConfigs.getByName("debug")
            } else {
                signingConfigs.getByName("release")
            }
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
