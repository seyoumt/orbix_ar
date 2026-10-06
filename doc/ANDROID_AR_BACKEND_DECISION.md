# Android AR backend decision

**Date:** 2026-09-23 (updated 2026-10-06)  
**Decision:** Ship **custom ARCore + GLES** (`AndroidArBackendKind.custom`) as the sole production Android backend.

## Context

Android capture previously used a vendored Sceneform / `arcore_flutter_plugin` stack via Flutter
Virtual Display (tap offset, no Hybrid Composition). Spikes compared SceneView vs a thin
custom ARCore renderer; custom won on ownership and transitive risk.

## Spike results

| Gate | 3A SceneView | 3B Custom ARCore+GLES |
|------|--------------|------------------------|
| Hybrid Composition | Pass | Pass |
| View-local `hitTest` | Pass | Pass |
| Markers + lines API | Pass | Pass |
| Dep / AGP pain | Higher (Filament) | Lowest |
| Long-term ownership | Track SceneView | Fully owned |

**Production:** custom. **SceneView:** archived under
[`android_backends/_archive/sceneview_spike`](../android_backends/_archive/sceneview_spike)
(not on the compile path).

**Sceneform:** archived under
[`android_backends/_archive/arcore_flutter_plugin`](../android_backends/_archive/arcore_flutter_plugin).

## Production default

```bash
flutter run   # custom Android AR backend only
```

Public Dart API unchanged: `ArMeasurementView`, `ArMeasurementController`, `ARService`.

## Reliability harden (2026-09-28)

Custom path hardened: single `Session.update` per frame, session lock, safe destroy,
attach-wait for visuals, tap serialization, `clearVisuals` on complete, native `onError`
surfacing, SceneView removed from Gradle deps.

## Visual + aim polish (2026-10-06)

Stayed on custom GLES (no SceneView restore). Closed the main “thin vs iOS” gap with
alpha blending, UV-sphere markers, soft filled + ring reticle, low-alpha plane outlines,
`Config.FocusMode.AUTO`, display-rotation resync each frame, and aim hit-test **extent**
fallback after polygon miss (Place still uses the current aim pose; Instant Placement and
Depth remain off).

Revisit SceneView only if product later requires Measure-app plane shimmer / PBR / occlusion.

## Option 3 (later)

Restore SceneView from archive + factory switch if product needs dual backends.
Do **not** maintain two production renderers unless explicitly approved.
