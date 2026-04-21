import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val isReleaseBuildRequested = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true) ||
        it.contains("Bundle", ignoreCase = true)
}

if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun isUnsetKeystoreValue(value: String?): Boolean {
    val normalized = value?.trim().orEmpty()
    return normalized.isEmpty() ||
        normalized.startsWith("replace-with-your-")
}

fun requireKeystoreValue(name: String): String {
    val value = keystoreProperties.getProperty(name)
    if (isUnsetKeystoreValue(value)) {
        throw GradleException(
            "android/key.properties is missing a real value for '$name'. " +
                "Open android/key.properties and replace the placeholder first.",
        )
    }
    return value.trim()
}

val releaseKeyAlias = if (hasReleaseKeystore) requireKeystoreValue("keyAlias") else null
val releaseKeyPassword = if (hasReleaseKeystore) requireKeystoreValue("keyPassword") else null
val releaseStorePassword = if (hasReleaseKeystore) requireKeystoreValue("storePassword") else null
val releaseStoreFile =
    if (hasReleaseKeystore) {
        rootProject.file(requireKeystoreValue("storeFile"))
    } else {
        null
    }

android {
    namespace = "app.via.visualassistant"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
            }
        }
    }

    defaultConfig {
        applicationId = "app.via.visualassistant"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (hasReleaseKeystore) {
                if (isReleaseBuildRequested && (releaseStoreFile == null || !releaseStoreFile.exists())) {
                    throw GradleException(
                        "Release keystore file not found at ${releaseStoreFile?.path}. " +
                            "Generate the keystore first or update storeFile in android/key.properties.",
                    )
                }
                signingConfig = signingConfigs.getByName("release")
            } else if (isReleaseBuildRequested) {
                throw GradleException(
                    "Missing android/key.properties. Copy android/key.properties.example " +
                        "to android/key.properties and fill in your release keystore details " +
                        "before building a release APK or AAB.",
                )
            }
        }
    }

    
}

flutter {
    source = "../.."
}
