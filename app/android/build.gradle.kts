allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Build output lives OUTSIDE OneDrive — otherwise OneDrive briefly locks files
// in the intermediates folders mid-Gradle, causing `mergeReleaseNativeLibs` to
// crash with AccessDeniedException.
val outOfOneDriveBuild: Directory = rootProject.layout.projectDirectory
    .dir("C:/build_out/print_collage_tool")
rootProject.layout.buildDirectory.value(outOfOneDriveBuild)

subprojects {
    val newSubprojectBuildDir: Directory = outOfOneDriveBuild.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
