plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.meowryang.pet_agent"

    compileSdk = 36

    defaultConfig {
        applicationId = "com.meowryang.pet_agent"

        minSdk = flutter.minSdkVersion
        targetSdk = 36

        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        release {
            // 테스트용 debug 서명 (배포 전 단계)
            signingConfig = signingConfigs.getByName("debug")

            // 릴리즈 최적화 (선택)
            isMinifyEnabled = false
            isShrinkResources = false
        }

        debug {
            isMinifyEnabled = false
        }
    }
}

flutter {
    source = "../.."
}
