import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../ar_service.dart';
import '../channel_android_ar_service.dart';

/// SceneView (ARSceneView) platform preview — Hybrid Composition.
class SceneviewArPreview extends StatefulWidget {
  const SceneviewArPreview({super.key, required this.service});

  static const viewType = 'ar_measurement/sceneview';
  static const channelName = 'ar_measurement/sceneview';

  final ARService service;

  @override
  State<SceneviewArPreview> createState() => _SceneviewArPreviewState();
}

class _SceneviewArPreviewState extends State<SceneviewArPreview> {
  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: SceneviewArPreview.viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        );
      },
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: SceneviewArPreview.viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: const <String, dynamic>{},
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        controller.addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
        controller.addOnPlatformViewCreatedListener((id) {
          final s = widget.service;
          if (s is ChannelAndroidArService) {
            s.attach(id);
          }
        });
        return controller..create();
      },
    );
  }
}
