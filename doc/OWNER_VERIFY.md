# Owner verification checklist

Complete these after Android AR backend / reliability changes. No secrets required for CI.

## 1. Local Android example build

```bash
cd example
flutter pub get
flutter build apk --debug
```

Confirm toolchain matches [SUPPORTED_TOOLCHAIN.md](SUPPORTED_TOOLCHAIN.md).
Backend decision: [ANDROID_AR_BACKEND_DECISION.md](ANDROID_AR_BACKEND_DECISION.md).

## 2. Device checklist (custom ARCore)

On a physical AR-capable phone (`flutter run` from `example/`):

- [ ] Cold start: camera permission prompt appears before AR preview
- [ ] Scan coaching (“Move your phone slowly…”) until first plane; then “Tap start point”
- [ ] Idle ~60s with no points: camera pauses; tap Resume; with a pending/measured point it does not pause
- [ ] No GL crash on open / resume / leave / background
- [ ] Plane / tracking starts; camera feed visible
- [ ] Tap places marker under finger (±~2–3 cm on a flat desk at ~0.5–1.5 m)
- [ ] Markers and the measurement line stay fixed on the surface when you walk / orbit the camera (no drift with tracking)
- [ ] Rapid double-taps do not create two “start” points (serialized)
- [ ] Second tap → marker + line + distance
- [ ] Undo removes last pair; Complete clears scene and returns a record
- [ ] On unsupported device / denied camera: error UI / `onError` — no crash
- [ ] Acceptable frame rate on a mid-range phone (no sustained jank on capture)

Details: [example/README.md](../example/README.md).

## 3. GitHub Actions

1. Push the repo to GitHub (if not already)
2. Ensure Actions are enabled for the repository
3. Confirm workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) is green:
   - Analyze & test
   - Example Android APK
   - Example iOS (no codesign)

## 4. Host integration

When embedding in a real app, follow [HOST_INTEGRATION.md](HOST_INTEGRATION.md)
exactly—especially no Sceneform / SceneView / pub.dev `arcore_flutter_plugin`, matching
Gradle/AGP/SDK, and copying `android.newDsl=false` / `android.builtInKotlin=false`
from the example.
