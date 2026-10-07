import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

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
  ///
  /// Placement is driven by [hitTestCenter] / [ArMeasurementController.placePoint];
  /// this stream is retained for advanced hosts and is not used for default capture.
  Stream<ARPoint> get pointDetectionStream;

  /// Stream of detected planes (package-internal use).
  Stream<ARPlane> get planeDetectionStream;

  /// Fires once when the scene can accept plane placement (surfaces tracked).
  ///
  /// May fire again after [clearVisuals] / a new capture session so hosts can
  /// re-show scan coaching. Readiness requires a short look-around scan, not
  /// merely the first detected plane.
  Stream<void> get trackingReadyStream;

  /// Scan quality while coaching (`0.0`–`1.0`). Reaches `1.0` as [trackingReadyStream] fires.
  Stream<double> get scanProgressStream;

  /// Whether the center-screen aim reticle currently hits a trackable plane.
  Stream<bool> get aimValidStream;

  /// Live preview segment length in meters while awaiting the end point.
  ///
  /// Emits `null` when preview is inactive or aim has no hit.
  Stream<double?> get previewDistanceStream;

  /// Native / session errors for host UI (may be empty on some backends).
  Stream<String> get platformErrorStream;

  /// Wait until the platform preview can accept visual commands.
  Future<void> ensureReady({Duration timeout = const Duration(seconds: 5)});

  /// Enable/disable the native oriented aim reticle (center hit + draw).
  Future<void> setAimingEnabled(bool enabled);

  /// World point under the viewport center, or `null` if no plane hit.
  Future<ARPoint?> hitTestCenter();

  /// Start (or clear with `null`) the rubber-band measure preview from [point].
  Future<void> setMeasurePreviewStart(ARPoint? point);

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
  static const _aimNodeId = '__aim_reticle__';
  static const _aimOuterId = '__aim_outer__';
  static const _aimCenterId = '__aim_center__';
  static const _previewLineId = '__preview_line__';

  ARKitController? _arkitController;
  final _logger = Logger();
  final _pointDetectionController = StreamController<ARPoint>.broadcast();
  final _planeDetectionController = StreamController<ARPlane>.broadcast();
  final _trackingReadyController = StreamController<void>.broadcast();
  final _scanProgressController = StreamController<double>.broadcast();
  final _aimValidController = StreamController<bool>.broadcast();
  final _previewDistanceController = StreamController<double?>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final Set<String> _nodeIds = {};
  final Map<String, double> _planeAreas = {};
  final Set<int> _yawBuckets = {};
  Completer<void>? _readyCompleter;
  bool _disposed = false;
  bool _trackingReadyEmitted = false;
  bool _hasSeenPlane = false;
  bool _aimingEnabled = false;
  bool _aimValid = false;
  bool _aimNodeAdded = false;
  bool _previewLineAdded = false;
  /// True while a hit-test / reticle update is in flight (drops overlapping ticks).
  bool _aimBusy = false;
  ARKitNode? _aimNode;
  ARPoint? _latestAimPoint;
  ARPoint? _previewStart;
  double? _lastPreviewDistance;
  DateTime _lastPreviewLineUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _aimMissSince;
  DateTime? _scanStartedAt;
  int _lastScanProgressPct = -1;

  static const _scanMin = Duration(milliseconds: 2500);
  static const _aimHold = Duration(milliseconds: 450);
  /// Preview line remove+add is costly; keep reticle fast and rebuild line slower.
  static const _previewLineMinInterval = Duration(milliseconds: 90);
  static const _minYawBuckets = 3;
  static const _yawBucketCount = 8;
  static const _minPlaneArea = 0.25;
  static const _minPlanes = 2;
  static const _accent = Color(0xFFF5C518);
  static const _accentSoft = Color(0xE6FFD54F);

  @override
  Stream<String> get platformErrorStream => _errorController.stream;

  @override
  Stream<void> get trackingReadyStream => _trackingReadyController.stream;

  @override
  Stream<double> get scanProgressStream => _scanProgressController.stream;

  @override
  Stream<bool> get aimValidStream => _aimValidController.stream;

  @override
  Stream<double?> get previewDistanceStream => _previewDistanceController.stream;

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
      final area = anchor.extent.x * anchor.extent.z;
      _planeAreas[anchor.identifier] = area;
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
      _scanStartedAt ??= DateTime.now();
      _evaluateScanReady();
    };

    // Placement is via placePoint / hitTestCenter — ignore scene taps.
    controller.onARTap = null;

    controller.updateAtTime = (_) {
      unawaited(_onFrameTick());
    };

    _logger.i('ARKit listeners configured (reticle aim + scan gate)');
  }

  void _resetScanState() {
    _scanStartedAt = _hasSeenPlane ? DateTime.now() : null;
    _yawBuckets.clear();
    _lastScanProgressPct = -1;
    if (!_hasSeenPlane) {
      _emitScanProgress(0);
    }
  }

  void _emitScanProgress(double progress) {
    final pct = (progress.clamp(0.0, 1.0) * 100).round();
    if (pct == _lastScanProgressPct) return;
    _lastScanProgressPct = pct;
    if (!_scanProgressController.isClosed) {
      _scanProgressController.add(progress.clamp(0.0, 1.0));
    }
  }

  Future<void> _onFrameTick() async {
    if (_disposed) return;
    if (!_trackingReadyEmitted) {
      await _sampleLookAround();
      _evaluateScanReady();
    }
    if (_aimingEnabled) {
      await _updateAimReticle();
    }
  }

  Future<void> _sampleLookAround() async {
    final controller = _arkitController;
    if (controller == null || !_hasSeenPlane) return;
    try {
      final euler = await controller.getCameraEulerAngles();
      // yaw component — bucket look direction while coaching.
      final yaw = euler.y;
      final norm = (yaw + 3.141592653589793) / (2 * 3.141592653589793);
      final bucket = (norm * _yawBucketCount).floor().clamp(0, _yawBucketCount - 1);
      _yawBuckets.add(bucket);
    } catch (_) {}
  }

  void _evaluateScanReady() {
    if (_disposed || _trackingReadyEmitted || !_hasSeenPlane) {
      if (!_hasSeenPlane) _emitScanProgress(0);
      return;
    }
    _scanStartedAt ??= DateTime.now();
    final elapsed = DateTime.now().difference(_scanStartedAt!);
    final maxArea = _planeAreas.values.fold<double>(0, (a, b) => a > b ? a : b);
    final planeCount = _planeAreas.length;

    final timeScore = (elapsed.inMilliseconds / _scanMin.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    final lookScore = (_yawBuckets.length / _minYawBuckets).clamp(0.0, 1.0);
    final areaScore = planeCount >= _minPlanes
        ? 1.0
        : (maxArea / _minPlaneArea).clamp(0.0, 1.0);
    final progress = [timeScore, lookScore, areaScore].reduce(
      (a, b) => a < b ? a : b,
    );
    _emitScanProgress(progress);

    final ready =
        elapsed >= _scanMin &&
        _yawBuckets.length >= _minYawBuckets &&
        (maxArea >= _minPlaneArea || planeCount >= _minPlanes);
    if (ready) {
      _emitTrackingReadyOnce();
    }
  }

  void _emitTrackingReadyOnce() {
    if (_disposed || _trackingReadyEmitted) return;
    _trackingReadyEmitted = true;
    _emitScanProgress(1);
    if (!_trackingReadyController.isClosed) {
      _trackingReadyController.add(null);
    }
  }

  void _emitAimValid(bool valid) {
    if (_disposed || _aimValid == valid) return;
    _aimValid = valid;
    if (!_aimValidController.isClosed) {
      _aimValidController.add(valid);
    }
  }

  ARKitTestResult? _preferredPlaneHit(List<ARKitTestResult> hits) {
    for (final type in [
      ARKitHitTestResultType.existingPlaneUsingGeometry,
      ARKitHitTestResultType.existingPlaneUsingExtent,
      ARKitHitTestResultType.estimatedHorizontalPlane,
    ]) {
      for (final hit in hits) {
        if (hit.type == type) return hit;
      }
    }
    return null;
  }

  ARPoint _pointFromHit(ARKitTestResult hit) {
    final translation = hit.worldTransform.getTranslation();
    return ARPoint(
      x: translation.x,
      y: translation.y,
      z: translation.z,
      label: 'aim',
      timestamp: DateTime.now(),
      planeId: hit.anchor?.identifier,
    );
  }

  Future<void> _updateAimReticle() async {
    if (_disposed || !_aimingEnabled || _aimBusy) return;
    // Serialize: one hit-test at a time; next frame runs as soon as this finishes
    // (no fixed 15 Hz throttle — that made the reticle feel laggy).
    _aimBusy = true;
    final controller = _arkitController;
    if (controller == null) {
      _aimBusy = false;
      return;
    }

    try {
      // performHitTest requires x,y in (0, 1]; center of the view.
      final hits = await controller.performHitTest(x: 0.5, y: 0.5);
      if (_disposed || !_aimingEnabled) return;
      final hit = _preferredPlaneHit(hits);
      if (hit == null) {
        await _clearAimWithHold();
        return;
      }

      _aimMissSince = null;
      final point = _pointFromHit(hit);
      _latestAimPoint = point;
      // Single parent transform (children ride along) — one channel write.
      await _showAimNode(hit.worldTransform);
      _maybeUpdatePreview(point);
      _emitAimValid(true);
    } catch (e, st) {
      _logger.w('Aim reticle update failed: $e', error: e, stackTrace: st);
      await _clearAimWithHold(force: true);
    } finally {
      _aimBusy = false;
    }
  }

  void _maybeUpdatePreview(ARPoint aim) {
    final start = _previewStart;
    if (start == null) {
      _emitPreviewDistance(null);
      return;
    }
    final dx = aim.x - start.x;
    final dy = aim.y - start.y;
    final dz = aim.z - start.z;
    _emitPreviewDistance(math.sqrt(dx * dx + dy * dy + dz * dz));

    final now = DateTime.now();
    if (now.difference(_lastPreviewLineUpdate) < _previewLineMinInterval) {
      return;
    }
    _lastPreviewLineUpdate = now;
    unawaited(_rebuildPreviewLine(start, aim));
  }

  Future<void> _clearAimWithHold({bool force = false}) async {
    final now = DateTime.now();
    if (!force) {
      _aimMissSince ??= now;
      if (now.difference(_aimMissSince!) < _aimHold) {
        // Keep last reticle / Place enabled through brief gaps.
        return;
      }
    }
    _aimMissSince = null;
    _latestAimPoint = null;
    await _hideAimNode();
    await _hidePreviewLine();
    _emitPreviewDistance(null);
    _emitAimValid(false);
  }

  void _emitPreviewDistance(double? meters) {
    if (_disposed) return;
    if (_lastPreviewDistance == meters) return;
    if (meters != null &&
        _lastPreviewDistance != null &&
        (meters - _lastPreviewDistance!).abs() < 0.002) {
      return;
    }
    _lastPreviewDistance = meters;
    if (!_previewDistanceController.isClosed) {
      _previewDistanceController.add(meters);
    }
  }

  Future<void> _updatePreviewLine(ARPoint aim) async {
    final start = _previewStart;
    if (start == null || _disposed) {
      await _hidePreviewLine();
      _emitPreviewDistance(null);
      return;
    }
    final dx = aim.x - start.x;
    final dy = aim.y - start.y;
    final dz = aim.z - start.z;
    _emitPreviewDistance(math.sqrt(dx * dx + dy * dy + dz * dz));
    _lastPreviewLineUpdate = DateTime.now();
    await _rebuildPreviewLine(start, aim);
  }

  Future<void> _rebuildPreviewLine(ARPoint start, ARPoint aim) async {
    final controller = _arkitController;
    if (controller == null || _disposed || _previewStart == null) return;
    // Rebuild — ARKitLine geometry is static once added.
    await _hidePreviewLine();
    if (_disposed || _previewStart == null) return;
    final line = ARKitLine(
      fromVector: vector.Vector3(start.x, start.y, start.z),
      toVector: vector.Vector3(aim.x, aim.y, aim.z),
      materials: [
        ARKitMaterial(
          lightingModelName: ARKitLightingModel.constant,
          diffuse: ARKitMaterialProperty.color(_accentSoft),
          transparency: 0.35,
        ),
      ],
    );
    await controller.add(ARKitNode(name: _previewLineId, geometry: line));
    _previewLineAdded = true;
  }

  Future<void> _hidePreviewLine() async {
    if (!_previewLineAdded) return;
    final controller = _arkitController;
    if (controller != null) {
      try {
        await controller.remove(_previewLineId);
      } catch (_) {}
    }
    _previewLineAdded = false;
  }

  Future<void> _showAimNode(vector.Matrix4 worldTransform) async {
    final controller = _arkitController;
    if (controller == null || _disposed) return;

    if (!_aimNodeAdded || _aimNode == null) {
      final outerMat = ARKitMaterial(
        lightingModelName: ARKitLightingModel.constant,
        diffuse: ARKitMaterialProperty.color(Colors.white),
        transparency: 0.25,
      );
      final ringMat = ARKitMaterial(
        lightingModelName: ARKitLightingModel.constant,
        diffuse: ARKitMaterialProperty.color(_accent),
      );
      final centerMat = ARKitMaterial(
        lightingModelName: ARKitLightingModel.constant,
        diffuse: ARKitMaterialProperty.color(_accent),
      );
      // Parent carries world pose; children are local — one transform write/frame.
      final parent = ARKitNode(
        name: _aimNodeId,
        transformation: worldTransform,
      );
      final outer = ARKitNode(
        name: _aimOuterId,
        geometry: ARKitTorus(
          ringRadius: 0.058,
          pipeRadius: 0.0025,
          materials: [outerMat],
        ),
      );
      final ring = ARKitNode(
        name: '${_aimNodeId}_ring',
        geometry: ARKitTorus(
          ringRadius: 0.03,
          pipeRadius: 0.0035,
          materials: [ringMat],
        ),
      );
      final center = ARKitNode(
        name: _aimCenterId,
        geometry: ARKitSphere(radius: 0.007, materials: [centerMat]),
      );
      await controller.add(parent);
      await controller.add(outer, parentNodeName: _aimNodeId);
      await controller.add(ring, parentNodeName: _aimNodeId);
      await controller.add(center, parentNodeName: _aimNodeId);
      _aimNode = parent;
      _aimNodeAdded = true;
    } else {
      _aimNode!.transform = worldTransform;
    }
  }

  Future<void> _hideAimNode() async {
    if (!_aimNodeAdded) return;
    final controller = _arkitController;
    if (controller == null) return;
    // Children first, then parent (SceneKit may not cascade via plugin remove).
    try {
      await controller.remove(_aimOuterId);
    } catch (_) {}
    try {
      await controller.remove('${_aimNodeId}_ring');
    } catch (_) {}
    try {
      await controller.remove(_aimCenterId);
    } catch (_) {}
    try {
      await controller.remove(_aimNodeId);
    } catch (_) {}
    _aimNode = null;
    _aimNodeAdded = false;
  }

  @override
  Stream<ARPoint> get pointDetectionStream => _pointDetectionController.stream;

  @override
  Stream<ARPlane> get planeDetectionStream => _planeDetectionController.stream;

  @override
  Future<void> setAimingEnabled(bool enabled) async {
    _aimingEnabled = enabled;
    if (!enabled) {
      await _clearAimWithHold(force: true);
    }
  }

  @override
  Future<ARPoint?> hitTestCenter() async {
    if (_disposed) return null;
    final controller = _arkitController;
    if (controller == null) return _latestAimPoint;
    try {
      final hits = await controller.performHitTest(x: 0.5, y: 0.5);
      final hit = _preferredPlaneHit(hits);
      if (hit == null) return _latestAimPoint;
      final point = _pointFromHit(hit);
      _latestAimPoint = point;
      return point;
    } catch (_) {
      return _latestAimPoint;
    }
  }

  @override
  Future<void> setMeasurePreviewStart(ARPoint? point) async {
    _previewStart = point;
    if (point == null) {
      await _hidePreviewLine();
      _emitPreviewDistance(null);
      return;
    }
    final aim = _latestAimPoint;
    if (aim != null) {
      await _updatePreviewLine(aim);
    }
  }

  @override
  Future<void> showPointMarker(String nodeId, ARPoint point) async {
    await ensureReady();
    final controller = _arkitController;
    if (controller == null) {
      throw StateError('ARKit controller not ready');
    }

    final core = ARKitMaterial(
      lightingModelName: ARKitLightingModel.constant,
      diffuse: ARKitMaterialProperty.color(_accent),
    );
    final rim = ARKitMaterial(
      lightingModelName: ARKitLightingModel.constant,
      diffuse: ARKitMaterialProperty.color(Colors.white),
    );
    final outer = ARKitNode(
      name: '${nodeId}_rim',
      geometry: ARKitSphere(radius: 0.014, materials: [rim]),
      position: vector.Vector3(point.x, point.y, point.z),
    );
    final inner = ARKitNode(
      name: nodeId,
      geometry: ARKitSphere(radius: 0.009, materials: [core]),
      position: vector.Vector3(point.x, point.y, point.z),
    );
    await controller.add(outer);
    await controller.add(inner);
    _nodeIds.add('${nodeId}_rim');
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
          diffuse: ARKitMaterialProperty.color(_accent),
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
    final rimId = '${nodeId}_rim';
    try {
      await controller.remove(rimId);
    } catch (_) {}
    try {
      await controller.remove(nodeId);
    } catch (_) {}
    _nodeIds.remove(rimId);
    _nodeIds.remove(nodeId);
  }

  @override
  Future<void> clearVisuals() async {
    if (_arkitController == null) return;
    await ensureReady();
    for (final id in List<String>.from(_nodeIds)) {
      await removeVisual(id);
    }
    await setMeasurePreviewStart(null);
    // Keep aim node if aiming; it is not in _nodeIds.
    // Match Android: re-run look-around coaching on the next session.
    _trackingReadyEmitted = false;
    _resetScanState();
  }

  @override
  Future<void> pauseTracking() async {
    await setAimingEnabled(false);
  }

  @override
  Future<void> resumeTracking() async {
    _trackingReadyEmitted = false;
    _resetScanState();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _aimingEnabled = false;
    await _hidePreviewLine();
    await _hideAimNode();
    await clearVisuals();
    _arkitController?.dispose();
    _arkitController = null;
    await _pointDetectionController.close();
    await _planeDetectionController.close();
    await _trackingReadyController.close();
    await _scanProgressController.close();
    await _aimValidController.close();
    await _previewDistanceController.close();
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
