import java.security.MessageDigest

group = "dev.flexvpn.flutter_singbox_vpn"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// ---------------------------------------------------------------------------
// sing-box core (libbox.aar). AGP forbids a raw local `.aar` as a library-module
// dependency ("Direct local .aar file dependencies are not supported when
// building an AAR"), and a flatDir dependency doesn't propagate to consuming
// apps. So we vendor the aar's pieces instead: extract classes.jar (consumed as
// a jar file dependency — those ARE allowed) and the per-ABI .so (consumed via
// jniLibs). Both then flow into any consuming app with zero extra config.
//
// The aar is too big for pub.dev, so it is NOT shipped in the package (see
// .pubignore). It is downloaded at build time from a release; override the URL
// with -PsingboxLibboxUrl=..., or drop a prebuilt libbox.aar into android/libs/.
// ---------------------------------------------------------------------------
val libboxAar = file("libs/libbox.aar")
val libboxUrl = (project.findProperty("singboxLibboxUrl") as String?)
    ?: "https://github.com/WillJard99/flutter_vpn_plugin/releases/download/v1.13.13/libbox.aar"
val libboxExtractDir = layout.buildDirectory.dir("libbox").get().asFile

// Resolve + unpack the core at CONFIGURATION time so the jar dependency and
// jniLibs srcDir below are populated before any task runs — this avoids the
// download-task-runs-too-late / generated-source ordering pitfalls that broke
// the build when the aar wasn't already on disk (the pub.dev case). A local
// android/libs/libbox.aar (offline dev) is used as-is; otherwise it's fetched
// once into the build dir.
val resolvedAar = if (libboxAar.exists()) libboxAar else file("$libboxExtractDir/libbox.aar")
if (!resolvedAar.exists()) {
    resolvedAar.parentFile.mkdirs()
    logger.lifecycle("flutter_singbox_vpn: downloading libbox.aar from $libboxUrl")
    try {
        uri(libboxUrl).toURL().openStream().use { input ->
            resolvedAar.outputStream().use { output -> input.copyTo(output) }
        }
    } catch (e: Exception) {
        resolvedAar.delete() // don't leave a truncated file behind
        throw GradleException(
            "flutter_singbox_vpn: failed to download libbox.aar from $libboxUrl. " +
            "Host the sing-box core on a release and pass -PsingboxLibboxUrl=..., " +
            "or drop libbox.aar into android/libs/. Cause: $e"
        )
    }
}
val expectedSha = (project.findProperty("singboxLibboxSha256") as String?)
    ?: "9aad340b455515811d37b38206d9dd8806a06ed3ac61e8284afc782a1aff37b4"
val actualSha = MessageDigest.getInstance("SHA-256")
    .digest(resolvedAar.readBytes()).joinToString("") { "%02x".format(it) }
require(actualSha.equals(expectedSha, ignoreCase = true)) {
    "libbox.aar checksum mismatch: expected $expectedSha, got $actualSha"
}
if (!file("$libboxExtractDir/classes.jar").exists()) {
    copy {
        from(zipTree(resolvedAar)) { include("classes.jar", "jni/**", "proguard.txt") }
        into(libboxExtractDir)
    }
}

android {
    namespace = "dev.flexvpn.flutter_singbox_vpn"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
            // Per-ABI libbox.so extracted from the aar.
            jniLibs.srcDir("$libboxExtractDir/jni")
        }
    }

    defaultConfig {
        minSdk = 24
        // Keep rules shipped inside the aar (gomobile bindings must not be stripped).
        if (file("$libboxExtractDir/proguard.txt").exists()) {
            consumerProguardFiles("$libboxExtractDir/proguard.txt")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // The Java bindings extracted from libbox.aar (a jar file dependency, which
    // — unlike an aar file dependency — AGP accepts in a library module).
    implementation(files("$libboxExtractDir/classes.jar"))
}
