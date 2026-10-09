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

- **Minimum:** Flutter **≥ 3.24** / Dart **≥ 3.5** (see [SUPPORTED_TOOLCHAIN.md](SUPPORTED_TOOLCHAIN.md)).
- **Example / CI pin** (Gradle 9.3.1, AGP 9.1.0, `compileSdk` 37) is what *this repo*
  builds with — not a hard requirement for every host. Prefer your Flutter version’s
  default Android toolchain unless you hit a build conflict.
- Treat Gradle/AGP bumps that change the **plugin** Android surface as **documented
  maintenance releases**.

### Android (host app)

| Setting | Value |
|--------|--------|
| `minSdk` | **≥ 24** |
| `compileSdk` | **≥ 34** (plugin compiles against 34; example uses 37) |
| Gradle / AGP | Flutter’s defaults for your SDK are fine; example pins are optional |

If you copy the example’s Android project, you may also want:

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

If the example’s SDK Platform 37 installs as `platforms/android-37.0`, ensure Gradle can
resolve `android-37` (symlink or reinstall platform).

### iOS (host app)

- `NSCameraUsageDescription` in `Info.plist`
- ARKit-capable device for capture; add `arkit` under `UIRequiredDeviceCapabilities` if the app requires AR

## Preflight: check AR before opening capture

Call a **camera-free** availability check on a home/settings screen so you can hide or
disable “Measure in AR” without mounting `ArMeasurementView` or requesting the camera:

```dart
final availability = await ArMeasurement.checkAvailability();
if (!availability.isSupported) {
  // Disable entry / show availability.message
  return;
}
// Navigate to ArMeasurementView only when supported
```

Convenience: `await ArMeasurement.isSupported()` → `bool`.

This uses ARCore availability (Android) or ARKit world-tracking configuration (iOS).
Web and desktop report unsupported. It does **not** request camera permission.

## Runtime: AR is not always available

Unsupported hardware / denied camera / init failure is still a **runtime** condition after
you open capture. Preflight is not enough alone:

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

## Capture interaction

Default capture is **reticle + Place**, not tap-on-scene:

1. While `!controller.isSceneReady`, show **look-around** coaching (not just “first plane”).
   Drive a progress UI with `controller.scanProgress` (`0`–`1`). Unlock needs time +
   camera yaw coverage + enough plane area/count.
2. When ready, a native **oriented aim reticle** tracks the surface under screen center.
3. Call `controller.placePoint()` (or use the default Place button) for start, then end.
4. After the start point, a live rubber-band preview line tracks from start to the aim
   reticle. Read `controller.previewDistanceMeters` for a live length chip (meters; `null`
   when inactive or aim has no hit).
5. Use `controller.canPlace` / `controller.aimValid` to enable Place in a custom `overlayBuilder`.
6. `undoLastMeasurement()` clears a pending start or deletes the last segment.

Scene taps are ignored for placement. Custom overlays should not rely on tap-to-place.
Brief aim misses keep the last reticle/Place enabled for a short hold so the button
does not flicker while looking around mapped surfaces.

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
