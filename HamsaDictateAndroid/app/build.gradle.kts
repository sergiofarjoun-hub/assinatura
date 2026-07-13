plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.hamsa.dictate"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.hamsa.dictate"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
        // O AAR do sherpa-onnx traz libs nativas para estas ABIs; arm64 cobre
        // qualquer celular moderno.
        ndk { abiFilters += listOf("arm64-v8a") }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { viewBinding = true }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    // Engine de ASR offline (Whisper via ONNX Runtime), com API Kotlin.
    // AAR oficial dos releases do GitHub (não é publicado no Maven Central):
    // baixado para app/libs/ pelo CI ou por scripts/fetch-sherpa.sh.
    implementation(files("libs/sherpa-onnx.aar"))
    // Extração do modelo .tar.bz2 baixado do GitHub releases.
    implementation("org.apache.commons:commons-compress:1.26.2")
}
