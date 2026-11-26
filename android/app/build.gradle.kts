import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val releaseSigningValues = listOf(
    "keyAlias",
    "keyPassword",
    "storeFile",
    "storePassword",
).associateWith { key -> keystoreProperties.getProperty(key)?.trim().orEmpty() }
val releaseSigningConfigured = releaseSigningValues.values.all { it.isNotEmpty() }
if (!releaseSigningConfigured) {
    logger.lifecycle(
        "Release signing is not configured; add android/key.properties with "
            + "keyAlias, keyPassword, storeFile, and storePassword.",
    )
}

android {
    namespace = "com.light1755.provisionalmessenger"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.light1755.provisionalmessenger"
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
        if (releaseSigningConfigured) {
            create("release") {
                keyAlias = releaseSigningValues["keyAlias"]
                keyPassword = releaseSigningValues["keyPassword"]
                storeFile = file(releaseSigningValues["storeFile"]!!)
                storePassword = releaseSigningValues["storePassword"]
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
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
