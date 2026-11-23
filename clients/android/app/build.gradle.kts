plugins {
	id("com.android.application") version "9.5.1"
	id("org.jetbrains.kotlin.plugin.compose") version "2.4.21"
}

android {
	namespace = "dev.hloth.nativenote"
	compileSdk {
		version = release(37) { minorApiLevel = 1 }
	}
	ndkVersion = "30.0.16248370"

	defaultConfig {
		applicationId = "dev.hloth.nativenote"
		minSdk = 31
		targetSdk = 36
		versionCode = 101
		versionName = "0.1.1"
		testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
		ndk {
			abiFilters += setOf("arm64-v8a", "armeabi-v7a", "x86_64")
			debugSymbolLevel = "NONE"
		}
	}

	buildTypes {
		debug {
			applicationIdSuffix = ".debug"
		}
		release {
			isMinifyEnabled = true
			proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
			vcsInfo.include = false
		}
	}

	dependenciesInfo {
		includeInApk = false
		includeInBundle = false
	}

	externalNativeBuild {
		cmake {
			path = file("src/main/cpp/CMakeLists.txt")
			version = "4.1.2"
		}
	}

	sourceSets {
		named("test") { kotlin.directories.add("src/sharedTest/kotlin") }
		named("androidTest") { kotlin.directories.add("src/sharedTest/kotlin") }
	}

	androidResources {
		localeFilters += "en"
	}

	packaging {
		jniLibs.keepDebugSymbols += "**/libandroidx.graphics.path.so"
	}

	buildFeatures {
		compose = true
	}

	lint {
		warningsAsErrors = true
		disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion", "OldTargetApi", "NotShrinkingResources")
		if (!providers.gradleProperty("playSdkIndex").isPresent) {
			disable += setOf(
				"PlaySdkIndexNonCompliant", "PlaySdkIndexVulnerability", "PlaySdkIndexGenericIssues", "PlaySdkIndexDeprecated", "RiskyLibrary", "OutdatedLibrary",
			)
		}
	}
}

kotlin {
	compilerOptions {
		allWarningsAsErrors = true
	}
}

val sqlcipherAmalgamation = tasks.register<Exec>("sqlcipherAmalgamation") {
	val kit = rootDir.resolve("../macos/native-note-kit")
	val script = kit.resolve("Scripts/sqlcipher-amalgamation.sh")
	commandLine(script)
	inputs.file(script)
	outputs.files(kit.resolve("Sources/SQLCipher/sqlite3.c"), kit.resolve("Sources/SQLCipher/include/sqlite3.h"))
}

tasks.configureEach {
	if (name.startsWith("configureCMake") || name.startsWith("buildCMake")) dependsOn(sqlcipherAmalgamation)
}

dependencies {
	val composeBom = platform("androidx.compose:compose-bom:2026.11.01")
	implementation(composeBom)
	implementation("androidx.compose.material3:material3")
	implementation("androidx.compose.material3.adaptive:adaptive-navigation")
	implementation("androidx.activity:activity-compose:1.13.0")
	implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

	testImplementation("junit:junit:4.13.2")
	testImplementation("org.json:json:20260814")

	androidTestImplementation(composeBom)
	androidTestImplementation("androidx.test:runner:1.7.0")
	androidTestImplementation("androidx.test.ext:junit:1.3.0")
	androidTestImplementation("androidx.compose.ui:ui-test-junit4")
	debugImplementation("androidx.compose.ui:ui-test-manifest")
}
