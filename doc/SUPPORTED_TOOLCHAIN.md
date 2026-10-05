# Supported toolchain

Pinned versions this package and its example are developed/tested against.
Host apps should match these when building Android AR.

| Component | Version |
|-----------|---------|
| Flutter | **3.47.2** (stable) — CI pin |
| Dart | **3.13.2** (`sdk: ^3.13.2` in package pubspec) |
| Gradle wrapper | **9.3.1** |
| Android Gradle Plugin (AGP) | **9.1.0** |
| Kotlin (example `settings.gradle.kts`) | **2.4.0** plugin id (with `android.builtInKotlin=false`) |
| Android `compileSdk` / `targetSdk` | **37** |
| Android `minSdk` | **24** |
| Android AR backend (production) | **Custom ARCore + GLES** ([decision](ANDROID_AR_BACKEND_DECISION.md)) |
| ARCore SDK | **com.google.ar:core:1.45.0** |
| `arkit_plugin` | **^1.5.0** |

## Example gradle flags

From [`example/android/gradle.properties`](../example/android/gradle.properties):

```properties
android.newDsl=false
android.builtInKotlin=false
```

The Android plugin library no longer ships a plugin-local AGP/KGP buildscript or
SceneView. It still applies `kotlin-android` so it builds with the example’s
`android.builtInKotlin=false`. Full Built-in Kotlin (`builtInKotlin=true`) can
follow when the example toolchain enables it.

## Release policy

- Changing Gradle / AGP / `compileSdk` expectations, or the Android AR backend, is a **documented** change in `CHANGELOG.md`.
- Do not assume newer Flutter templates work without re-checking this matrix and CI.

## Updating the pin

When upgrading Flutter locally:

1. Update this table
2. Update `.github/workflows/ci.yml` Flutter version
3. Run example `flutter build apk` and `flutter build ios --no-codesign`
4. Re-verify the device checklist in [OWNER_VERIFY.md](OWNER_VERIFY.md)
