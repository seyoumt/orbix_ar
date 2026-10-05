# Changelog

## 0.1.0

- Package and public API named `ar_measurement` (`ArMeasurementView`, `ArMeasurementController`, `MeasurementRecord`, …)
- Initial package layout (Widget + Controller public API)
- `ArMeasurementView` / `ArMeasurementController` for embeddable AR capture
- Unified on `ARPoint` (removed dual `AR3DPoint` public type)
- Real AR visuals: sphere markers + measurement line (ARKit / Android GLES)
- Capture UX: `CapturePhase`, pending start, distance list, undo last, complete gate
- Optional persistence via `MeasurementRecordStore` + `SqliteMeasurementRecordStore`
- Platform classes kept package-private; barrel exports only the stable API
- Example host app with camera/AR permissions and device checklist
- Unit tests with `FakeARService` for session / undo / complete
- **Android AR rewrite:** production backend is owned **custom ARCore + GLES** (Hybrid Composition, view-local hit tests). Sceneform and SceneView spikes archived under `android_backends/_archive/`. See `doc/ANDROID_AR_BACKEND_DECISION.md`.
- **Android AR harden:** single `Session.update` per frame, session lock, safe destroy + EGL depth, camera permission + attach-wait for visuals, tap serialization, `clearVisuals` on complete, native `onError` → controller, lean Android library Gradle (no SceneView / no plugin-local KGP classpath)
- Android markers/lines use ARCore **Anchors** so points stay fixed as tracking refines when the camera moves
- Scan-ready coaching: `isSceneReady` + overlay prompt until the first tracked plane (taps were silent before surfaces exist)
- Idle thermal pause: after 60s with no points, pause ARCore session (not close); resume via overlay; never pause once a point/measurement exists
- Host docs + toolchain matrix updated for ARCore 1.45 / custom backend; GitHub Actions CI for analyze/test + example Android/iOS builds
- Example AndroidManifest uses `tools:replace` for `com.google.ar.core` (required vs plugin optional)
- `ArMeasurementView` mounts the AR preview only after support + permission succeed
- Android depth: plane-only in-polygon hit tests
