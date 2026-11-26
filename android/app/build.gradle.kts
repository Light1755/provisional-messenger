import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Pinned SDK levels and release identity. The version matches pubspec.yaml
// (1.0.3+4); the Flutter tool writes the same values into local.properties as
// flutter.versionCode / flutter.versionName during a normal `flutter build`.
val appCompileSdk = 36
val appMinSdk = 24
val appTargetSdk = 36
val appVersionCode = 4
val appVersionName = "1.0.3"

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Local builds read android/key.properties; CI supplies the same four values
// through the environment. Nothing here is ever written to logs or the repo.
fun signingValue(propertyKey: String, vararg envKeys: String): String {
    val fromProperties = keystoreProperties.getProperty(propertyKey)?.trim().orEmpty()
    if (fromProperties.isNotEmpty()) return fromProperties
    for (envKey in envKeys) {
        val fromEnv = System.getenv(envKey)?.trim().orEmpty()
        if (fromEnv.isNotEmpty()) return fromEnv
    }
    return ""
}

val releaseSigningValues = mapOf(
    "keyAlias" to signingValue("keyAlias", "KEY_ALIAS", "RELEASE_KEY_ALIAS"),
    "keyPassword" to signingValue("keyPassword", "KEY_PASSWORD", "RELEASE_KEY_PASSWORD"),
    "storeFile" to signingValue("storeFile", "KEYSTORE_FILE", "RELEASE_STORE_FILE"),
    "storePassword" to signingValue("storePassword", "KEYSTORE_PASSWORD", "RELEASE_STORE_PASSWORD"),
)
val missingSigningValues = releaseSigningValues.filter { it.value.isEmpty() }.keys.toList()
val releaseSigningConfigured = missingSigningValues.isEmpty()
val releaseStoreFile = releaseSigningValues["storeFile"]?.let { file(it) }

// Only enforce signing when a release task is actually requested, so debug
// builds keep working on machines with no keystore. A release build must never
// fall back to the debug signing config.
val releaseTaskRequested = gradle.startParameter.taskNames.any { taskName ->
    val name = taskName.substringAfterLast(':')
    name.contains("release", ignoreCase = true)
        || name in setOf("assemble", "build", "bundle", "install", "publish")
}
if (releaseTaskRequested && !releaseSigningConfigured) {
    throw GradleException(
        "Release build requested without signing configuration. Set keyAlias, "
            + "keyPassword, storeFile, and storePassword in android/key.properties, "
            + "or set KEY_ALIAS, KEY_PASSWORD, KEYSTORE_FILE, and KEYSTORE_PASSWORD "
            + "in the environment. Missing: "
            + missingSigningValues.joinToString(", ")
            + ". Release builds do not fall back to debug signing.",
    )
}
if (releaseTaskRequested && releaseStoreFile != null && !releaseStoreFile.isFile) {
    throw GradleException(
        "Release keystore file not found: ${releaseSigningValues["storeFile"]}",
    )
}

android {
    namespace = "com.light1755.provisionalmessenger"
    compileSdk = appCompileSdk
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.light1755.provisionalmessenger"
        minSdk = appMinSdk
        targetSdk = appTargetSdk
        versionCode = appVersionCode
        versionName = appVersionName
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                keyAlias = releaseSigningValues["keyAlias"]
                keyPassword = releaseSigningValues["keyPassword"]
                storeFile = releaseStoreFile!!
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
