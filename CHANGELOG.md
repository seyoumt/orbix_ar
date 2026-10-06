# Changelog

## Unreleased

- Broaden support to Flutter **≥ 3.24** / Dart **≥ 3.5** (was effectively 3.47 / 3.13 via `sdk: ^3.13.2`)
- Widen runtime dependency ranges so older SDKs can resolve compatible transitive versions
- Lower plugin `compileSdk` to **34**; document minimum vs CI-tested toolchain separately
- **Reticle capture:** replace tap-to-place with scan coaching + native oriented aim reticle + Place (`placePoint` / `canPlace` / `aimValid`)
- Breaking UX: scene taps no longer place points; hosts should use Place or call `controller.placePoint()`
- **Look-around scan gate:** `isSceneReady` waits for time + yaw coverage + plane area (not first plane only); `scanProgress` for coaching UI; short aim-hold to reduce Place flicker
- **Live measure preview:** after the first Place, a rubber-band line follows the aim reticle until end Place; `previewDistanceMeters` + default HUD live length chip; refined gold/white markers, dashed preview line, and oriented reticle (no per-frame anchors)
- **Android GLES polish:** alpha blending, UV-sphere markers, soft filled reticle, plane outline coaching, `FocusMode.AUTO`, aim hit-test extent fallback (Place still uses aim pose; SceneView remains archive-only)
- **Android far aim:** keep reticle when looking past the mapped plane patch (infinite-plane hitTest + raycast onto expanded extents; longer aim-hold)

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
