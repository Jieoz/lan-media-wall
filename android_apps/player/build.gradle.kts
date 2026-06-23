// Root build script. Plugin versions are declared in gradle/libs.versions.toml
// and applied (without versions) in the module scripts.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
}
