allprojects {
    repositories {
        google()
        mavenCentral()
    }

    // Android Gradle Plugin's release-only lint tasks crash on the Java 17
    // runtime bundled with this Flutter toolchain (List.removeLast was added
    // in Java 21). Dart analysis and CI cover app correctness; these tasks
    // only lint bundled plugin sources and are not needed to ship the APK.
    tasks.configureEach {
        if (name.startsWith("lintVital")) {
            enabled = false
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
