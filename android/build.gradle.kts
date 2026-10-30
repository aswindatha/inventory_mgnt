allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Version skew in the Flutter SDK.
//
// `packages/integration_test/android/build.gradle.kts` hardcodes
// `classpath("com.android.tools.build:gradle:8.11.0")` in its own buildscript
// block, while `flutter create` generated this app with AGP 9.1.0 on Gradle
// 9.3.1. AGP 8.11 predates Gradle 9 and cannot configure under it, which
// surfaces as a misleading
//   "'kotlin-android' plugin requires one of the Android Gradle plugins"
// plus a NullPointerException from the evaluation listener.
//
// Force every subproject onto the app's AGP version so the plugin module
// configures with the same toolchain as everything else. Remove this if the SDK
// stops pinning AGP in the plugin.
subprojects {
    buildscript {
        configurations.configureEach {
            resolutionStrategy.eachDependency {
                if (requested.group == "com.android.tools.build" &&
                    requested.name == "gradle"
                ) {
                    useVersion("9.1.0")
                    because(
                        "match the app's AGP so the integration_test plugin " +
                            "subproject can configure under Gradle 9",
                    )
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
