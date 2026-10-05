# AR Measurement

Embeddable Flutter package for capturing AR measurements with ARCore (Android) and ARKit (iOS).

## For host apps

Before integrating, read:

- **[Host integration](doc/HOST_INTEGRATION.md)** — API rules, Android/iOS setup, AR unsupported handling
- **[Supported toolchain](doc/SUPPORTED_TOOLCHAIN.md)** — pinned Flutter / Gradle / AGP / SDK versions
- **[Android AR backend decision](doc/ANDROID_AR_BACKEND_DECISION.md)** — custom ARCore production backend

Android AR is an owned ARCore + GLES `PlatformView` (not Sceneform). Do **not**
add pub.dev `arcore_flutter_plugin` to your app.

## Capture loop (verified vertical slice)

1. Tap **start** point in the AR scene (marker appears)
2. Tap **end** point (second marker + line; distance shown with ±7.5 cm margin)
3. **Undo** last tap/measurement if needed
4. **Complete** → host receives a `MeasurementRecord`

## Requirements

- Flutter **≥ 3.24.0** / Dart **≥ 3.5.0**
- Physical AR-capable Android (ARCore) or iOS (ARKit) device
- Details: [SUPPORTED_TOOLCHAIN.md](doc/SUPPORTED_TOOLCHAIN.md)

## Install

```yaml
dependencies:
  ar_measurement: ^0.1.0
```

For a local path dependency while developing:

```yaml
dependencies:
  ar_measurement:
    path: ../ar_measurement
```

## Quick start

```dart
import 'package:ar_measurement/ar_measurement.dart';

final controller = ArMeasurementController();

Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => Scaffold(
      body: ArMeasurementView(
        controller: controller,
        onSessionCompleted: (record) {
          Navigator.pop(context, record);
        },
        onError: (e) {
          // AR unsupported / init failed — show fallback UI
        },
      ),
    ),
  ),
);
```

## Optional persistence

```dart
import 'package:ar_measurement/persistence.dart';

final store = SqliteMeasurementRecordStore();
await store.initialize();
await store.save(record);
```

## Platform setup

**Mobile only.** Use a physical AR-capable device. Full details: [HOST_INTEGRATION.md](doc/HOST_INTEGRATION.md).

### iOS (`Info.plist`)

- `NSCameraUsageDescription`
- `UIRequiredDeviceCapabilities` → `arkit` (if AR is required)

### Android

- Gradle **9.3.1**, AGP **9.1**, `compileSdk`/`targetSdk` **37**, `minSdk` ≥ **24**
- Plugin declares ARCore / `camera.ar` / GLES as **optional** (app installs on non-AR devices)
- For AR-only apps, override to `required` in the host manifest (see example)
- Handle unsupported devices via `onError` / `controller.isSupported`
- `android.newDsl=false` and `android.builtInKotlin=false` (see example)
- Production backend: custom ARCore + GLES ([decision](doc/ANDROID_AR_BACKEND_DECISION.md))

## Example

```bash
cd example
flutter pub get
flutter run
```

Demos: minimal embed, custom overlay, SQLite history, optional GPS.

### Device checklist

- [ ] Plane / tracking starts
- [ ] First tap shows a marker
- [ ] Second tap shows marker + line + distance
- [ ] Undo removes last pair from UI and scene
- [ ] Complete returns a record (history updates when using SQLite)
- [ ] On a non-AR device/emulator: error / unsupported UI appears (no crash)

Owner verification steps: [doc/OWNER_VERIFY.md](doc/OWNER_VERIFY.md).

## Public API

| Import | Contents |
|--------|----------|
| `ar_measurement.dart` | `ArMeasurementView`, `ArMeasurementController`, `CapturePhase`, models, `ARService` / `ARServiceFactory`, `MeasurementMath` |
| `persistence.dart` | `MeasurementRecordStore`, `SqliteMeasurementRecordStore` |

Platform classes (`IOSARService`, Android channel services) are **not** exported. Do not import `src/` from host apps.

## License

MIT — see [LICENSE](LICENSE).
