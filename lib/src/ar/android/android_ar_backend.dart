import 'package:flutter/widgets.dart';

import '../ar_service.dart';
import 'channel_android_ar_service.dart';
import 'previews/custom_ar_preview.dart';

/// Android AR production backend (custom ARCore + GLES).
///
/// SceneView spike archived under `android_backends/_archive/` — not on the
/// production compile path. Dual backends (option 3) can restore from archive.
enum AndroidArBackendKind {
  /// Thin ARCore + GLES — production default.
  custom,
}

/// Resolves backend; always [custom] after SceneView strip.
AndroidArBackendKind resolveAndroidArBackend() => AndroidArBackendKind.custom;

/// Creates the Android [ARService] and matching preview widget.
abstract final class AndroidArBackend {
  static AndroidArBackendKind get current => resolveAndroidArBackend();

  static ARService createService([AndroidArBackendKind? kind]) {
    return ChannelAndroidArService(
      viewType: CustomArPreview.viewType,
      channelName: CustomArPreview.channelName,
    );
  }

  static Widget createPreview({
    Key? key,
    required ARService service,
    AndroidArBackendKind? kind,
  }) {
    return CustomArPreview(key: key, service: service);
  }
}
