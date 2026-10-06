import 'dart:async';

import 'package:ar_measurement/ar_measurement.dart';
import 'package:ar_measurement/src/ar/ar_service.dart' show ARPlane;

/// In-memory [ARService] for unit tests (no device / plugins).
class FakeARService implements ARService {
  final _points = StreamController<ARPoint>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _trackingReady = StreamController<void>.broadcast();
  final _scanProgress = StreamController<double>.broadcast();
  final _aimValid = StreamController<bool>.broadcast();
  final _previewDistance = StreamController<double?>.broadcast();
  final List<String> markers = [];
  final List<String> lines = [];
  int pauseCount = 0;
  int resumeCount = 0;
  bool supported = true;
  bool ready = true;
  bool aimingEnabled = false;
  ARPoint? centerHit;
  ARPoint? previewStart;
  Duration? readyDelay;

  void emitPoint(ARPoint point) => _points.add(point);

  void emitError(String message) => _errors.add(message);

  void emitTrackingReady() => _trackingReady.add(null);

  void emitScanProgress(double value) => _scanProgress.add(value);

  void emitAimValid(bool valid) => _aimValid.add(valid);

  void emitPreviewDistance(double? meters) => _previewDistance.add(meters);

  @override
  Future<void> initialize() async {}

  @override
  Stream<ARPoint> get pointDetectionStream => _points.stream;

  @override
  Stream<ARPlane> get planeDetectionStream => const Stream.empty();

  @override
  Stream<void> get trackingReadyStream => _trackingReady.stream;

  @override
  Stream<double> get scanProgressStream => _scanProgress.stream;

  @override
  Stream<bool> get aimValidStream => _aimValid.stream;

  @override
  Stream<double?> get previewDistanceStream => _previewDistance.stream;

  @override
  Stream<String> get platformErrorStream => _errors.stream;

  @override
  Future<void> ensureReady({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (readyDelay != null) {
      await Future<void>.delayed(readyDelay!);
    }
    if (!ready) {
      throw TimeoutException('Fake AR not ready', timeout);
    }
  }

  @override
  Future<void> setAimingEnabled(bool enabled) async {
    aimingEnabled = enabled;
  }

  @override
  Future<ARPoint?> hitTestCenter() async => centerHit;

  @override
  Future<void> setMeasurePreviewStart(ARPoint? point) async {
    previewStart = point;
    if (point == null) {
      emitPreviewDistance(null);
    }
  }

  @override
  Future<void> showPointMarker(String nodeId, ARPoint point) async {
    await ensureReady();
    markers.add(nodeId);
  }

  @override
  Future<void> showMeasurementLine(
    String nodeId,
    ARPoint start,
    ARPoint end,
  ) async {
    await ensureReady();
    lines.add(nodeId);
  }

  @override
  Future<void> removeVisual(String nodeId) async {
    markers.remove(nodeId);
    lines.remove(nodeId);
  }

  @override
  Future<void> clearVisuals() async {
    await ensureReady();
    markers.clear();
    lines.clear();
    previewStart = null;
    emitPreviewDistance(null);
  }

  @override
  Future<void> pauseTracking() async {
    pauseCount++;
  }

  @override
  Future<void> resumeTracking() async {
    resumeCount++;
  }

  @override
  Future<void> dispose() async {
    await _points.close();
    await _errors.close();
    await _trackingReady.close();
    await _scanProgress.close();
    await _aimValid.close();
    await _previewDistance.close();
  }

  @override
  Future<bool> isSupported() async => supported;
}
