plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.third_eye_assist"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.example.third_eye_assist"

        // tflite_flutter needs 21+; camera package needs 21+.
        minSdk = 24
        targetSdk = 35

        versionCode = flutter.versionCode
        versionName = flutter.versionName

        multiDexEnabled = true

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    // Prevent duplicate .so errors when multiple plugins bundle native libraries.
    packaging {
        jniLibs {
            pickFirsts += listOf(
                "lib/arm64-v8a/libtensorflowlite_jni.so",
                "lib/armeabi-v7a/libtensorflowlite_jni.so",
                "lib/arm64-v8a/libtensorflowlite_gpu_jni.so",
                "lib/armeabi-v7a/libtensorflowlite_gpu_jni.so",
                "lib/arm64-v8a/libc++_shared.so",
                "lib/armeabi-v7a/libc++_shared.so"
            )
            useLegacyPackaging = false
        }
    }

    // Do not compress .tflite files. TFLite needs them uncompressed.
    androidResources {
        noCompress += listOf("tflite", "lite")
    }

    buildTypes {
        getByName("release") {
            // Use debug signing for now so flutter run --release works.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}