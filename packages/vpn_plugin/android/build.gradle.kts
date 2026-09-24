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

// Use the pinned source-built core with the BMray REALITY compatibility patch.
// Falling back to the old prebuilt AAR would reintroduce the handshake failure.
val resolvedAar = file("libs/libbox.aar")
val checksumFile = file("libs/libbox.aar.sha256")
require(resolvedAar.exists() && checksumFile.exists()) {
    "Build the patched core first: bash scripts/build_libbox_android.sh"
}
val expectedSha = checksumFile.readText().trim()
val actualSha = MessageDigest.getInstance("SHA-256")
    .digest(resolvedAar.readBytes()).joinToString("") { "%02x".format(it) }
require(actualSha.equals(expectedSha, ignoreCase = true)) {
    "libbox.aar checksum mismatch: expected $expectedSha, got $actualSha"
}
val libboxExtractDir = layout.buildDirectory.dir("libbox").get().asFile
val extractedChecksum = file("$libboxExtractDir/source.sha256")
if (!extractedChecksum.exists() || extractedChecksum.readText() != actualSha) {
    libboxExtractDir.deleteRecursively()
    copy {
        from(zipTree(resolvedAar)) { include("classes.jar", "jni/**", "proguard.txt") }
        into(libboxExtractDir)
    }
    extractedChecksum.writeText(actualSha)
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
