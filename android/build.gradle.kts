allprojects {
    repositories {
        google()
        mavenCentral()
        // usb-serial-for-android yalnızca JitPack üzerinden yayınlanıyor.
        maven { url = uri("https://jitpack.io") }
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

// universal_ble 3.x, AGP 9'un yerleşik Kotlin desteğini varsayıp `kotlin {}`
// bloğunu eklentisiz kullanıyor. AGP 8'de Kotlin eklentisini biz uyguluyoruz;
// AGP 9'a geçilince bu blok silinebilir.
subprojects {
    if (name == "universal_ble") {
        plugins.withId("com.android.library") {
            apply(plugin = "org.jetbrains.kotlin.android")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
