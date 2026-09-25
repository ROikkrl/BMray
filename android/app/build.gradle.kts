plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingStore = System.getenv("BMRAY_KEYSTORE_FILE")
val signingAlias = System.getenv("BMRAY_KEY_ALIAS")
val signingStorePassword = System.getenv("BMRAY_KEYSTORE_PASSWORD")
val signingKeyPassword = System.getenv("BMRAY_KEY_PASSWORD")
val hasReleaseSigning = listOf(signingStore, signingAlias, signingStorePassword, signingKeyPassword)
    .all { !it.isNullOrEmpty() }

android {
    namespace = "com.bolvankamax.bmray"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion
    packaging {
        jniLibs.useLegacyPackaging = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        
        applicationId = "com.bolvankamax.bmray"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("bmrayRelease") {
                storeFile = file(signingStore!!)
                storePassword = signingStorePassword
                keyAlias = signingAlias
                keyPassword = signingKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("bmrayRelease")
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
