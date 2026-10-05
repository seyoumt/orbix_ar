# Supported toolchain

## Minimum supported (package consumers)

| Component | Minimum |
|-----------|---------|
| Flutter | **≥ 3.24.0** |
| Dart | **≥ 3.5.0** (`sdk: '>=3.5.0 <4.0.0'`) |
| Android `minSdk` | **24** |
| Android `compileSdk` (plugin) | **34** |
| `arkit_plugin` | **^1.5.0** |

Dependency version ranges in `pubspec.yaml` are intentionally wide so pub can
resolve older transitive versions (e.g. `sqflite` 2.3.x / 2.4.1) on older SDKs
and newer ones on current stable.

## Tested / CI pin (this repo)

Pinned versions this package and its example are developed and CI-tested against.
Analyze/test CI runs on both the **minimum** (3.24.0) and this pin. Prefer matching
the pin when building the **example** Android AR app.

| Component | Version |
|-----------|---------|
| Flutter | **3.47.2** (stable) — CI pin |
| Dart | **3.13.2** |
| Gradle wrapper | **9.3.1** |
| Android Gradle Plugin (AGP) | **9.1.0** |
| Kotlin (example `settings.gradle.kts`) | **2.4.0** plugin id (with `android.builtInKotlin=false`) |
| Android `compileSdk` / `targetSdk` (example) | **37** |
| Android AR backend (production) | **Custom ARCore + GLES** ([decision](ANDROID_AR_BACKEND_DECISION.md)) |
| ARCore SDK | **com.google.ar:core:1.45.0** |

Host apps on Flutter **3.24–3.46** should use their Flutter-era Gradle/AGP
defaults; they do **not** need the example’s Gradle 9 / AGP 9.1 pin unless they
hit a documented Android build issue.

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

- Changing the **minimum** Flutter/Dart floor, Gradle / AGP / `compileSdk`
  expectations, or the Android AR backend is a **documented** change in
  `CHANGELOG.md`.
- Do not assume newer Flutter templates work without re-checking this matrix and CI.

## Updating the pin

When upgrading Flutter locally:

1. Update the **Tested / CI pin** table
2. Update `.github/workflows/ci.yml` Flutter version
3. Run example `flutter build apk` and `flutter build ios --no-codesign`
4. Re-verify the device checklist in [OWNER_VERIFY.md](OWNER_VERIFY.md)
