# Example host app

Demonstrates embedding `ar_measurement` as a path dependency.

```bash
flutter pub get
flutter run
```

Use a **physical** iOS or Android device with AR support for the capture loop.
Simulators/emulators and non-AR phones will not complete measurements — that is expected.

## Unsupported AR (host apps must handle this)

AR availability is a **runtime** concern. A successful Gradle/Xcode build does **not** mean capture works on every device.

In this example:

- `ArMeasurementView` shows an error message when `controller.isSupported == false` or init fails
- `onError` shows a SnackBar so the host can react (dialog, fallback screen, etc.)

When integrating in your app:

```dart
ArMeasurementView(
  controller: controller,
  onError: (e) {
    // Unsupported device, camera denied, or AR init failure
  },
  onSessionCompleted: (record) { /* ... */ },
);
```

Also read `controller.error`, `controller.isSupported`, and `controller.phase` (`CapturePhase`).
Full rules: [`doc/HOST_INTEGRATION.md`](../doc/HOST_INTEGRATION.md).

## Device checklist (AR-capable phone)

1. Open **Minimal embed** — camera permission is requested before the preview mounts
2. Tracking / plane detection starts (no GL crash on open/resume)
3. First tap shows a marker **under the finger** (±~2–3 cm on a desk)
4. Rapid taps do not create duplicate start points
5. Second tap shows marker + line + distance (±7.5 cm)
6. **Undo** removes the last pair; **Complete** clears the scene and returns home

## Android depth / far taps

ARCore on most phones is **monocular** (no LiDAR). Accurate far placement needs a
**detected plane** under the tap (in-polygon hits only).

Tips: pan the phone until planes cover the surface, then tap on the plane.

Android production preview uses **Hybrid Composition** with an owned ARCore+GLES
view. See [`doc/ANDROID_AR_BACKEND_DECISION.md`](../doc/ANDROID_AR_BACKEND_DECISION.md).

## Device checklist (unsupported / no AR)

1. Open **Minimal embed**
2. See in-view error (or SnackBar via `onError`) — app does not crash
3. No `MeasurementRecord` is produced

Owner CI/build steps: [`doc/OWNER_VERIFY.md`](../doc/OWNER_VERIFY.md).
