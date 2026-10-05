import 'package:arcore_flutter_plugin/src/arcore_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

typedef PlatformViewCreatedCallback = void Function(int id);

/// ARCore platform view.
///
/// Uses Flutter's default [AndroidView] path (Virtual Display / TLHC fallback).
/// **Do not** use [PlatformViewsService.initExpensiveAndroidView] (Hybrid
/// Composition): Sceneform/ARCore require their own GL context and crash with
/// [MissingGlContextException] under HC.
class ArCoreAndroidView extends AndroidView {
  ArCoreAndroidView({
    Key? key,
    required String viewType,
    PlatformViewCreatedCallback? onPlatformViewCreated,
    ArCoreViewType arCoreViewType = ArCoreViewType.STANDARDVIEW,
    bool debug = false,
  }) : super(
          key: key,
          viewType: viewType,
          onPlatformViewCreated: onPlatformViewCreated,
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
          creationParams: <String, dynamic>{
            'type': arCoreViewType == ArCoreViewType.AUGMENTEDFACE
                ? 'faces'
                : arCoreViewType == ArCoreViewType.AUGMENTEDIMAGES
                    ? 'augmented'
                    : 'standard',
            'debug': debug,
          },
          creationParamsCodec: const StandardMessageCodec(),
        );
}
