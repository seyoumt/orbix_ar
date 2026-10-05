# Archived SceneView spike (3A)

Reference-only. **Not** linked from `pubspec.yaml` or `android/build.gradle`.

| Path | Contents |
|------|----------|
| `kotlin/` | `SceneviewArMeasurementView` + factory |
| `dart/` | `sceneview_ar_preview.dart` |

Production backend: custom ARCore + GLES. To restore option-3 dual backends,
re-add `io.github.sceneview:arsceneview`, register the factory in the plugin,
and wire `AndroidArBackendKind.sceneview`.

See [`doc/ANDROID_AR_BACKEND_DECISION.md`](../../doc/ANDROID_AR_BACKEND_DECISION.md).
