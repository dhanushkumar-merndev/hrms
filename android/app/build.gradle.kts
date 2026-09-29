import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.internalhrms.hrms"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.internalhrms.hrms"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 8.0+: hardware key attestation with biometric-bound keys.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing from ../../.env (ANDROID_KEYSTORE_*). Without a keystore
    // the release build falls back to debug signing (staging only).
    val env = Properties().apply {
        val f = rootProject.file("../.env")
        if (f.exists()) f.readLines().forEach { line ->
            val t = line.trim()
            if (t.isNotEmpty() && !t.startsWith("#") && t.contains("=")) {
                setProperty(t.substringBefore("=").trim(), t.substringAfter("=").trim().trim('"'))
            }
        }
    }
    val keystorePath = env.getProperty("ANDROID_KEYSTORE_PATH").orEmpty()
    signingConfigs {
        if (keystorePath.isNotEmpty()) {
            create("release") {
                storeFile = rootProject.file("../$keystorePath").takeIf { it.exists() } ?: file(keystorePath)
                storePassword = env.getProperty("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = env.getProperty("ANDROID_KEY_ALIAS")
                keyPassword = env.getProperty("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePath.isNotEmpty()) signingConfigs.getByName("release")
                            else signingConfigs.getByName("debug")
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
    implementation("androidx.biometric:biometric:1.1.0")
}
