import 'package:arcore_flutter_plugin/arcore_flutter_plugin.dart';
import 'package:flutter/material.dart';

import '../../ar_service.dart';
import '../legacy_sceneform_android_ar_service.dart';

class LegacySceneformPreview extends StatelessWidget {
  const LegacySceneformPreview({super.key, required this.service});

  final ARService service;

  @override
  Widget build(BuildContext context) {
    return ArCoreView(
      enableTapRecognizer: true,
      enablePlaneRenderer: true,
      enableUpdateListener: true,
      onArCoreViewCreated: (controller) {
        final s = service;
        if (s is LegacySceneformAndroidArService) {
          s.setARCoreController(controller);
        }
      },
    );
  }
}
