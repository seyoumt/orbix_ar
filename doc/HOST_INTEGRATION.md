# Host app integration

Rules for developers embedding `ar_measurement` in another Flutter app.

## Public API only

```dart
import 'package:ar_measurement/ar_measurement.dart';
import 'package:ar_measurement/persistence.dart'; // optional
```

- Use `ArMeasurementView`, `ArMeasurementController`, models, and (optionally) `MeasurementRecordStore`.
- **Do not** import `package:ar_measurement/src/...`.
- **Do not** import AR plugin types (`arkit_plugin`) from host code unless you are doing advanced custom wiring.

## Android AR (critical)

This package **owns** Android AR via a thin ARCore + GLES `PlatformView`
(Hybrid Composition). Public API stays `ArMeasurementView` / `ARService`.

- Depend only on `ar_measurement` (path/git). **Do not** add pub.dev
  `arcore_flutter_plugin`, Sceneform, or SceneView — they are not used in production.
- Plugin defaults (merged into the host): `com.google.ar.core=optional`,
  `android.hardware.camera.ar` and GLES 3.0 with `required="false"`. Non-AR
  devices can install the app; check support at runtime (below).
- If you set `com.google.ar.core` to `required` while the plugin declares
  `optional`, add `tools:replace="android:value"` on your `<meta-data>` (see the example app).
- Same for AR-only Play filtering: override `camera.ar` / GLES to
  `required="true"` with `tools:replace` if needed.

See [ANDROID_AR_BACKEND_DECISION.md](ANDROID_AR_BACKEND_DECISION.md) and
[ANDROID_AR_EXIT_RAMP.md](ANDROID_AR_EXIT_RAMP.md).

## Supported toolchain

Match [SUPPORTED_TOOLCHAIN.md](SUPPORTED_TOOLCHAIN.md). Treat Gradle/AGP bumps from this package as **documented maintenance releases**.

### Android (host app)

| Setting | Value |
|--------|--------|
| Gradle wrapper | **9.3.1** |
| Android Gradle Plugin | **9.1.0** |
| `compileSdk` / `targetSdk` | **37** |
| `minSdk` | **≥ 24** |

In `android/gradle.properties` (copy from the example until plugins migrate):

```properties
android.newDsl=false
android.builtInKotlin=false
android.useAndroidX=true
```

`AndroidManifest.xml`:

- `android.permission.CAMERA`
- Package default: `camera.ar` + GLES `required="false"`, ARCore meta-data `optional`
- AR-only host: set `camera.ar` / GLES to `required="true"` and ARCore meta-data to
  `required` (use `tools:replace` when overriding the plugin; see the example app)
- Optional-AR host: keep the package defaults so Play does not hide the app on non-AR devices

If SDK Platform 37 installs as `platforms/android-37.0`, ensure Gradle can resolve `android-37` (symlink or reinstall platform).

### iOS (host app)

- `NSCameraUsageDescription` in `Info.plist`
- ARKit-capable device for capture; add `arkit` under `UIRequiredDeviceCapabilities` if the app requires AR

## Runtime: AR is not always available

Unsupported hardware / denied camera / init failure is a **runtime** condition, not a successful measurement session.

```dart
ArMeasurementView(
  controller: controller,
  onError: (e) {
    // Show UI: AR unavailable — do not assume capture succeeded
  },
  onSessionCompleted: (record) { /* persist */ },
);
```

Also check `controller.isSupported`, `controller.error`, and `controller.phase` (`CapturePhase`).

## Quick embed

```dart
final controller = ArMeasurementController();

await Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => Scaffold(
      body: ArMeasurementView(
        controller: controller,
        onSessionCompleted: (record) => Navigator.pop(context, record),
        onError: (e) { /* snackbar / dialog */ },
      ),
    ),
  ),
);
```

Dispose the controller when the route is popped if you own its lifecycle.

## Persistence

Optional. Use `package:ar_measurement/persistence.dart` or implement `MeasurementRecordStore` yourself. The controller never requires SQLite.
