# Android AR exit ramp

## Status: complete

Production Android AR is the **owned custom ARCore + GLES** backend.
See [ANDROID_AR_BACKEND_DECISION.md](ANDROID_AR_BACKEND_DECISION.md).

Sceneform and SceneView spikes are **archived** (not on the pub/Gradle path):

- [`android_backends/_archive/arcore_flutter_plugin`](../android_backends/_archive/arcore_flutter_plugin)
- [`android_backends/_archive/sceneview_spike`](../android_backends/_archive/sceneview_spike)

## Non-goals (unchanged)

- Changing `MeasurementRecord` / measurement math
- Changing host import paths
- Dual production backends now (archive keeps a restore path for option 3)
