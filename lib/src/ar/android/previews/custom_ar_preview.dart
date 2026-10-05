import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../ar_service.dart';
import '../channel_android_ar_service.dart';

/// Thin ARCore + GLES platform preview — Hybrid Composition.
class CustomArPreview extends StatefulWidget {
  const CustomArPreview({super.key, required this.service});

  static const viewType = 'ar_measurement/custom';
  static const channelName = 'ar_measurement/custom';

  final ARService service;

  @override
  State<CustomArPreview> createState() => _CustomArPreviewState();
}

class _CustomArPreviewState extends State<CustomArPreview> {
  int? _viewId;

  @override
  void dispose() {
    final s = widget.service;
    if (s is ChannelAndroidArService) {
      s.detach(_viewId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: CustomArPreview.viewType,
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
          viewType: CustomArPreview.viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: const <String, dynamic>{},
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        controller.addOnPlatformViewCreatedListener(
          params.onPlatformViewCreated,
        );
        controller.addOnPlatformViewCreatedListener((id) {
          _viewId = id;
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
