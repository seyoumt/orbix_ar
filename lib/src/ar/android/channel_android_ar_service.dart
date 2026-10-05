import 'dart:async';

import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

import '../../models/measurement_record.dart';
import '../ar_service.dart';

/// Shared Dart side for the custom ARCore platform view.
class ChannelAndroidArService implements ARService {
  ChannelAndroidArService({required this.viewType, required this.channelName});

  final String viewType;
  final String channelName;
  final _logger = Logger();
  final _pointDetectionController = StreamController<ARPoint>.broadcast();
  final _planeDetectionController = StreamController<ARPlane>.broadcast();
  final _trackingReadyController = StreamController<void>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final Set<String> _nodeIds = {};

  MethodChannel? _channel;
  int? _attachedViewId;
  Completer<void>? _attachCompleter;
  bool _disposed = false;

  bool get isAttached => _channel != null && !_disposed;

  @override
  Stream<String> get platformErrorStream => _errorController.stream;

  @override
  Stream<void> get trackingReadyStream => _trackingReadyController.stream;

  /// Called from the preview when the platform view is created.
  void attach(int viewId) {
    if (_disposed) return;
    _attachedViewId = viewId;
    _channel = MethodChannel('${channelName}_$viewId');
    _channel!.setMethodCallHandler(_onMethodCall);
    final pending = _attachCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
    _attachCompleter = null;
    _logger.i('Attached Android AR channel ${channelName}_$viewId ($viewType)');
  }

  /// Called when the platform view is disposed.
  void detach([int? viewId]) {
    if (viewId != null &&
        _attachedViewId != null &&
        viewId != _attachedViewId) {
      return; // Stale dispose from a previous view.
    }
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _attachedViewId = null;
    if (_attachCompleter != null && !_attachCompleter!.isCompleted) {
      _attachCompleter!.completeError(
        StateError('AR platform view detached before attach completed'),
      );
    }
    _attachCompleter = null;
  }

  @override
  Future<void> ensureReady({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_disposed) {
      throw StateError('ChannelAndroidArService disposed');
    }
    if (_channel != null) return;
    _attachCompleter ??= Completer<void>();
    await _attachCompleter!.future.timeout(
      timeout,
      onTimeout: () {
        throw TimeoutException(
          'Timed out waiting for Android AR platform view ($viewType)',
          timeout,
        );
      },
    );
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (_disposed) return;
    switch (call.method) {
      case 'onTap':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        _pointDetectionController.add(
          ARPoint(
            x: (args['x'] as num).toDouble(),
            y: (args['y'] as num).toDouble(),
            z: (args['z'] as num).toDouble(),
            label: 'tap',
            timestamp: DateTime.now(),
          ),
        );
        break;
      case 'onPlane':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        _planeDetectionController.add(
          ARPlane(
            id:
                args['id'] as String? ??
                DateTime.now().millisecondsSinceEpoch.toString(),
            extentX: (args['extentX'] as num?)?.toDouble() ?? 0,
            extentZ: (args['extentZ'] as num?)?.toDouble() ?? 0,
            detectedAt: DateTime.now(),
            alignment: args['alignment'] as String? ?? 'horizontal',
          ),
        );
        break;
      case 'onTrackingReady':
        if (!_trackingReadyController.isClosed) {
          _trackingReadyController.add(null);
        }
        break;
      case 'onError':
        final message = '${call.arguments}';
        _logger.e('Android AR error: $message');
        if (!_errorController.isClosed) {
          _errorController.add(message);
        }
        break;
    }
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    await ensureReady();
    final channel = _channel;
    if (channel == null || _disposed) {
      throw StateError('Android AR channel not attached; cannot $method');
    }
    await channel.invokeMethod<void>(method, args);
  }

  @override
  Future<void> initialize() async {
    _logger.i('Initializing ChannelAndroidArService ($viewType)');
  }

  @override
  Stream<ARPoint> get pointDetectionStream => _pointDetectionController.stream;

  @override
  Stream<ARPlane> get planeDetectionStream => _planeDetectionController.stream;

  @override
  Future<void> showPointMarker(String nodeId, ARPoint point) async {
    await _invoke('addMarker', {
      'id': nodeId,
      'x': point.x,
      'y': point.y,
      'z': point.z,
    });
    _nodeIds.add(nodeId);
  }

  @override
  Future<void> showMeasurementLine(
    String nodeId,
    ARPoint start,
    ARPoint end,
  ) async {
    await _invoke('addLine', {
      'id': nodeId,
      'x0': start.x,
      'y0': start.y,
      'z0': start.z,
      'x1': end.x,
      'y1': end.y,
      'z1': end.z,
    });
    _nodeIds.add(nodeId);
  }

  @override
  Future<void> removeVisual(String nodeId) async {
    await _invoke('remove', {'id': nodeId});
    _nodeIds.remove(nodeId);
  }

  @override
  Future<void> clearVisuals() async {
    await _invoke('clear');
    _nodeIds.clear();
  }

  @override
  Future<void> pauseTracking() async {
    await _invoke('pauseTracking');
  }

  @override
  Future<void> resumeTracking() async {
    await _invoke('resumeTracking');
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    try {
      if (_channel != null) {
        await _channel!.invokeMethod<void>('clear');
      }
    } catch (_) {}
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _attachedViewId = null;
    _nodeIds.clear();
    await _pointDetectionController.close();
    await _planeDetectionController.close();
    await _trackingReadyController.close();
    await _errorController.close();
  }

  @override
  Future<bool> isSupported() async {
    try {
      const availability = MethodChannel(
        'ar_measurement/availability',
      );
      final result = await availability.invokeMethod<bool>('isArCoreSupported');
      return result == true;
    } catch (_) {
      return false;
    }
  }
}
