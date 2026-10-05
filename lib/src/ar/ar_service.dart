import 'dart:async';
import 'dart:io' show Platform;

import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

import '../models/measurement_record.dart';
import 'android/android_ar_backend.dart';

export 'android/android_ar_backend.dart';

/// Abstraction layer for AR functionality.
///
/// Hosts normally use [ArMeasurementController] rather than calling this directly.
abstract class ARService {
  /// Prepare the platform AR stack (no-op on some backends).
  Future<void> initialize();

  /// Stream of tapped/detected points in world space.
  Stream<ARPoint> get pointDetectionStream;

  /// Stream of detected planes (package-internal use).
  Stream<ARPlane> get planeDetectionStream;

  /// Fires once when the scene can accept plane taps (surfaces tracked).
  ///
  /// May fire again after [clearVisuals] / a new capture session so hosts can
  /// re-show scan coaching.
  Stream<void> get trackingReadyStream;

  /// Native / session errors for host UI (may be empty on some backends).
  Stream<String> get platformErrorStream;

  /// Wait until the platform preview can accept visual commands.
  Future<void> ensureReady({Duration timeout = const Duration(seconds: 5)});

  /// Show a sphere marker at [point]. [nodeId] is used for later removal.
  Future<void> showPointMarker(String nodeId, ARPoint point);

  /// Show a line between two points (best-effort on each platform).
  Future<void> showMeasurementLine(String nodeId, ARPoint start, ARPoint end);

  /// Remove a previously placed visual by [nodeId].
  Future<void> removeVisual(String nodeId);

  /// Remove all package-managed visuals.
  Future<void> clearVisuals();

  /// Pause camera / tracking to reduce heat (no-op if unsupported).
  Future<void> pauseTracking();

  /// Resume after [pauseTracking].
  Future<void> resumeTracking();

  /// Tear down streams and native resources.
  Future<void> dispose();

  /// Whether this device can run the package AR backend.
  Future<bool> isSupported();
}

/// Detected AR plane (not part of the public package barrel).
class ARPlane {
  final String id;
  final double extentX;
  final double extentZ;
  final DateTime detectedAt;
  final String alignment;

  ARPlane({
    required this.id,
    required this.extentX,
    required this.extentZ,
    required this.detectedAt,
    required this.alignment,
  });
}

/// iOS-specific implementation using ARKit.
class IOSARService extends ARService {
  ARKitController? _arkitController;
  final _logger = Logger();
  final _pointDetectionController = StreamController<ARPoint>.broadcast();
  final _planeDetectionController = StreamController<ARPlane>.broadcast();
  final _trackingReadyController = StreamController<void>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final Set<String> _nodeIds = {};
  Completer<void>? _readyCompleter;
  bool _disposed = false;
  bool _trackingReadyEmitted = false;
  bool _hasSeenPlane = false;

  @override
  Stream<String> get platformErrorStream => _errorController.stream;

  @override
  Stream<void> get trackingReadyStream => _trackingReadyController.stream;

  @override
  Future<void> initialize() async {
    _logger.i('Initializing IOSARService (ARKit)');
  }

  void setARKitController(ARKitController controller) {
    if (_disposed) return;
    _arkitController = controller;
    _setupARKitListeners();
    final pending = _readyCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
    _readyCompleter = null;
  }

  @override
  Future<void> ensureReady({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_disposed) throw StateError('IOSARService disposed');
    if (_arkitController != null) return;
    _readyCompleter ??= Completer<void>();
    await _readyCompleter!.future.timeout(
      timeout,
      onTimeout: () {
        throw TimeoutException('Timed out waiting for ARKit view', timeout);
      },
    );
  }

  void _setupARKitListeners() {
    final controller = _arkitController;
    if (controller == null) return;

    controller.onAddNodeForAnchor = (ARKitAnchor anchor) {
      if (anchor is! ARKitPlaneAnchor) return;
      _planeDetectionController.add(
        ARPlane(
          id: anchor.identifier,
          extentX: anchor.extent.x,
          extentZ: anchor.extent.z,
          detectedAt: DateTime.now(),
          alignment: 'horizontal',
        ),
      );
      _hasSeenPlane = true;
      _emitTrackingReadyOnce();
    };

    controller.onARTap = (List<ARKitTestResult> hits) {
      if (hits.isEmpty) return;
      final preferred = hits.where(
        (h) =>
            h.type == ARKitHitTestResultType.featurePoint ||
            h.type == ARKitHitTestResultType.existingPlaneUsingExtent ||
            h.type == ARKitHitTestResultType.existingPlaneUsingGeometry,
      );
      final hit = preferred.isNotEmpty ? preferred.first : hits.first;
      final translation = hit.worldTransform.getColumn(3);
      _pointDetectionController.add(
        ARPoint(
          x: translation.x,
          y: translation.y,
          z: translation.z,
          label: 'tap',
          timestamp: DateTime.now(),
          planeId: hit.anchor?.identifier,
        ),
      );
    };

    _logger.i('ARKit listeners configured');
  }

  void _emitTrackingReadyOnce() {
    if (_disposed || _trackingReadyEmitted) return;
    _trackingReadyEmitted = true;
    if (!_trackingReadyController.isClosed) {
      _trackingReadyController.add(null);
    }
  }

  @override
  Stream<ARPoint> get pointDetectionStream => _pointDetectionController.stream;

  @override
  Stream<ARPlane> get planeDetectionStream => _planeDetectionController.stream;

  @override
  Future<void> showPointMarker(String nodeId, ARPoint point) async {
    await ensureReady();
    final controller = _arkitController;
    if (controller == null) {
      throw StateError('ARKit controller not ready');
    }

    final material = ARKitMaterial(
      lightingModelName: ARKitLightingModel.constant,
      diffuse: ARKitMaterialProperty.color(Colors.blueAccent),
    );
    final sphere = ARKitSphere(radius: 0.012, materials: [material]);
    final node = ARKitNode(
      name: nodeId,
      geometry: sphere,
      position: vector.Vector3(point.x, point.y, point.z),
    );
    await controller.add(node);
    _nodeIds.add(nodeId);
  }

  @override
  Future<void> showMeasurementLine(
    String nodeId,
    ARPoint start,
    ARPoint end,
  ) async {
    await ensureReady();
    final controller = _arkitController;
    if (controller == null) {
      throw StateError('ARKit controller not ready');
    }

    final line = ARKitLine(
      fromVector: vector.Vector3(start.x, start.y, start.z),
      toVector: vector.Vector3(end.x, end.y, end.z),
      materials: [
        ARKitMaterial(
          lightingModelName: ARKitLightingModel.constant,
          diffuse: ARKitMaterialProperty.color(Colors.yellowAccent),
        ),
      ],
    );
    final node = ARKitNode(name: nodeId, geometry: line);
    await controller.add(node);
    _nodeIds.add(nodeId);
  }

  @override
  Future<void> removeVisual(String nodeId) async {
    await ensureReady();
    final controller = _arkitController;
    if (controller == null) return;
    await controller.remove(nodeId);
    _nodeIds.remove(nodeId);
  }

  @override
  Future<void> clearVisuals() async {
    if (_arkitController == null) return;
    await ensureReady();
    for (final id in List<String>.from(_nodeIds)) {
      await removeVisual(id);
    }
    // Match Android: allow coaching again on the next session.
    _trackingReadyEmitted = false;
    if (_hasSeenPlane) {
      _emitTrackingReadyOnce();
    }
  }

  @override
  Future<void> pauseTracking() async {
    // arkit_plugin does not expose session pause.
  }

  @override
  Future<void> resumeTracking() async {
    if (_hasSeenPlane) {
      _trackingReadyEmitted = false;
      _emitTrackingReadyOnce();
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await clearVisuals();
    _arkitController?.dispose();
    _arkitController = null;
    await _pointDetectionController.close();
    await _planeDetectionController.close();
    await _trackingReadyController.close();
    await _errorController.close();
  }

  @override
  Future<bool> isSupported() async {
    return ARKitPlugin.checkConfiguration(ARKitConfiguration.worldTracking);
  }
}

/// Factory to create the correct AR service based on platform.
class ARServiceFactory {
  /// Returns an Android or iOS [ARService], or throws on unsupported platforms.
  static ARService createARService() {
    if (kIsWeb) {
      throw UnsupportedError('AR is not supported on web');
    }
    if (Platform.isAndroid) {
      return AndroidArBackend.createService();
    }
    if (Platform.isIOS) {
      return IOSARService();
    }
    throw UnsupportedError('AR is only supported on Android and iOS');
  }
}
