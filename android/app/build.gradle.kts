plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.google.devtools.ksp")
}

android {
    namespace = "com.zeyanlin.novelreader"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.zeyanlin.novelreader"
        minSdk = 26
        targetSdk = 37
        // Kept by hand in step with the iOS Info.plist now that the two apps match: the same
        // marketing version, and the iOS build number as the code, so one number names a release.
        versionCode = 20
        versionName = "1.8.1"
    }

    buildFeatures {
        compose = true
    }

    buildTypes {
        release {
            // The GitHub release key, handed in by CI. It must never change: an APK signed
            // with another key cannot install over the last one, and uninstalling first
            // takes the shelf and reading progress with it. Not the Play key — Play signs
            // its own copy, so the two never update into each other anyway.
            System.getenv("ANDROID_KEYSTORE")?.let { path ->
                signingConfig = signingConfigs.create("github") {
                    storeFile = file(path)
                    storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                    keyAlias = "release"
                    keyPassword = storePassword
                }
            }
        }
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.13.0")
    // Rule files and extractor payloads are the iOS app's JSON, byte for byte.
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    implementation("androidx.room:room-runtime:2.8.5")
    implementation("androidx.room:room-ktx:2.8.5")
    ksp("androidx.room:room-compiler:2.8.5")

    testImplementation("junit:junit:4.13.2")
}
