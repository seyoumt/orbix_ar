import 'dart:async';

import 'package:ar_measurement/ar_measurement.dart';
import 'package:ar_measurement/src/ar/ar_service.dart' show ARPlane;

/// In-memory [ARService] for unit tests (no device / plugins).
class FakeARService implements ARService {
  final _points = StreamController<ARPoint>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _trackingReady = StreamController<void>.broadcast();
  final List<String> markers = [];
  final List<String> lines = [];
  int pauseCount = 0;
  int resumeCount = 0;
  bool supported = true;
  bool ready = true;
  Duration? readyDelay;

  void emitPoint(ARPoint point) => _points.add(point);

  void emitError(String message) => _errors.add(message);

  void emitTrackingReady() => _trackingReady.add(null);

  @override
  Future<void> initialize() async {}

  @override
  Stream<ARPoint> get pointDetectionStream => _points.stream;

  @override
  Stream<ARPlane> get planeDetectionStream => const Stream.empty();

  @override
  Stream<void> get trackingReadyStream => _trackingReady.stream;

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
  }

  @override
  Future<bool> isSupported() async => supported;
}
