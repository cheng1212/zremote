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
    // Register BEFORE evaluationDependsOn (which evaluates :app right away):
    // some plugins hardcode an old compileSdk (file_picker 8.x pins 34) while
    // first-party plugins' AAR metadata demands >= 36; raise every Android
    // library subproject to at least 36 after its own evaluation.
    afterEvaluate {
        extensions
            .findByType(com.android.build.api.dsl.LibraryExtension::class.java)
            ?.let { lib ->
                if ((lib.compileSdk ?: 0) < 36) {
                    lib.compileSdk = 36
                }
            }
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
