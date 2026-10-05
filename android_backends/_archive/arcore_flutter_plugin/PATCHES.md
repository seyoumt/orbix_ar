# Vendored & patched `arcore_flutter_plugin` 0.1.0+patched.7

This tree is **owned by** `ar_measurement`. Host apps must not add
pub.dev `arcore_flutter_plugin` (it overrides this path dependency).

Upstream pub.dev package still uses `jcenter()` and lacks an AGP `namespace`,
which breaks Gradle 9 / AGP 9 builds. Google's Sceneform 1.17.1 also fails
manifest merger (duplicate `com.google.ar.sceneform` namespace).

## Patches applied

| Area | Change |
|------|--------|
| Repositories | `jcenter()` → `mavenCentral()` |
| AGP | Add `namespace` |
| Toolchain | Kotlin / compile options for modern AGP (`compileSdk 37`) |
| Sceneform | Google `core`/`assets`/`ux` 1.17.1 → `com.gorisse.thomas.sceneform:sceneform:1.23.0` |
| ARCore pin | **`com.google.ar:core:1.31.0`** (must match Sceneform 1.23; newer ARCore crashes with `NoSuchMethodError` on `acquireEnvironmentalHdrCubeMap()[ArImage]`) |
| Light estimation | `LightEstimationConfig.DISABLED` + `Config.LightEstimationMode.DISABLED` (measurement UX does not need HDR) |
| Platform view | Host `ArSceneView` in a non-null `FrameLayout` so Flutter VirtualDisplay `getView()` never NPEs after destroy |
| Shape center | ShapeFactory center `(0,0.15,0)` → `(0,0,0)` so markers sit on hit points |
| Tap hit-test | Plane-only placement (no feature-point fallback — those sit “in front” with bad depth); view-local `hitTest(x,y)` |
| Platform view mode | Keep Virtual Display / default [AndroidView] — Hybrid Composition (`initExpensiveAndroidView`) crashes Sceneform with `MissingGlContextException` |
| Kotlin 2.x | `MotionEvent?` null-check in `ArCoreView.kt` |
| Sceneform 1.23 API | `setupSession` → `setSession`; `cameraStreamRenderPriority` → `setCameraStreamRenderPriority` |
| Materials | Use `MaterialFactory` (no `com.google.ar.sceneform.rendering.R`) |
| Models | Drop removed `RenderableSource`; load glTF/GLB via `ModelRenderable` + Filament |

Do not edit the pub-cache copy; change this tree instead.

Long-term replacement plan: [`doc/ANDROID_AR_EXIT_RAMP.md`](../../doc/ANDROID_AR_EXIT_RAMP.md).
