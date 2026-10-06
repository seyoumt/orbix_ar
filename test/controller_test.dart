import 'dart:async';

import 'package:ar_measurement/ar_measurement.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_ar_service.dart';

void main() {
  late FakeARService fake;
  late ArMeasurementController controller;

  setUp(() {
    fake = FakeARService();
    controller = ArMeasurementController(
      arService: fake,
      requestCameraPermission: () async => true,
    );
  });

  tearDown(() {
    controller.dispose();
  });

  ARPoint point(double x, double y, double z) =>
      ARPoint(x: x, y: y, z: z, label: 'p', timestamp: DateTime(2026));

  Future<void> readyToPlace() async {
    await controller.startSession();
    fake.emitTrackingReady();
    fake.emitAimValid(true);
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'startSession then two placePoint calls create a measurement',
    () async {
      await readyToPlace();
      expect(controller.phase, CapturePhase.awaitingStart);
      expect(controller.canPlace, isTrue);

      fake.centerHit = point(0, 0, 0);
      expect(await controller.placePoint(), isTrue);
      expect(controller.phase, CapturePhase.awaitingEnd);
      expect(fake.markers, contains('pending_start'));

      fake.centerHit = point(3, 4, 0);
      expect(await controller.placePoint(), isTrue);

      expect(controller.measurementCount, 1);
      expect(controller.measurements.first.distanceMeters, closeTo(5.0, 1e-9));
      expect(controller.phase, CapturePhase.readyToComplete);
      expect(fake.lines.length, 1);
    },
  );

  test('placePoint returns false when center hit is null', () async {
    await readyToPlace();
    fake.centerHit = null;
    expect(await controller.placePoint(), isFalse);
    expect(controller.measurementCount, 0);
    expect(controller.phase, CapturePhase.awaitingStart);
  });

  test('pending start enables measure preview; undo clears it', () async {
    await readyToPlace();
    fake.centerHit = point(1, 0, 0);
    await controller.placePoint();
    expect(controller.phase, CapturePhase.awaitingEnd);
    expect(fake.previewStart, isNotNull);
    expect(fake.previewStart!.x, 1);

    fake.emitPreviewDistance(0.42);
    await Future<void>.delayed(Duration.zero);
    expect(controller.previewDistanceMeters, closeTo(0.42, 1e-9));

    await controller.undoLastMeasurement();
    expect(fake.previewStart, isNull);
    expect(controller.previewDistanceMeters, isNull);
  });

  test('undoLastMeasurement removes measurement and visuals', () async {
    await controller.startSession();
    await controller.addMeasurement(
      name: 'M1',
      startPoint: point(0, 0, 0),
      endPoint: point(1, 0, 0),
    );
    expect(controller.measurementCount, 1);
    expect(fake.markers.length, greaterThanOrEqualTo(2));

    await controller.undoLastMeasurement();
    expect(controller.measurementCount, 0);
    expect(fake.markers, isEmpty);
    expect(fake.lines, isEmpty);
  });

  test(
    'undo clears pending start without removing completed measurements',
    () async {
      await readyToPlace();
      await controller.addMeasurement(
        name: 'M1',
        startPoint: point(0, 0, 0),
        endPoint: point(1, 0, 0),
      );
      fake.centerHit = point(2, 0, 0);
      await controller.placePoint();
      expect(controller.phase, CapturePhase.awaitingEnd);

      await controller.undoLastMeasurement();
      expect(controller.phase, CapturePhase.readyToComplete);
      expect(controller.measurementCount, 1);
    },
  );

  test('completeSession returns record and clears native visuals', () async {
    await controller.startSession();
    await controller.addMeasurement(
      name: 'M1',
      startPoint: point(0, 0, 0),
      endPoint: point(1, 0, 0),
    );

    final record = await controller.completeSession();
    expect(record.status, 'completed');
    expect(record.measurements, hasLength(1));
    expect(controller.hasActiveSession, isFalse);
    expect(controller.phase, CapturePhase.idle);
    expect(fake.markers, isEmpty);
    expect(fake.lines, isEmpty);
  });

  test('completeSession with no measurements throws', () async {
    await controller.startSession();
    expect(
      () => controller.completeSession(),
      throwsA(isA<ArMeasurementException>()),
    );
  });

  test('unsupported device throws on startSession', () async {
    fake.supported = false;
    expect(
      () => controller.startSession(),
      throwsA(isA<ArMeasurementException>()),
    );
  });

  test('camera permission denied fails initialize', () async {
    final denied = ArMeasurementController(
      arService: fake,
      requestCameraPermission: () async => false,
    );
    addTearDown(denied.dispose);

    await denied.initialize();
    expect(denied.isSupported, isFalse);
    expect(denied.error, contains('Camera permission'));
  });

  test('platform errors surface on controller.error', () async {
    await controller.initialize();
    fake.emitError('Camera not available');
    await Future<void>.delayed(Duration.zero);
    expect(controller.error, contains('Camera not available'));
  });

  test('trackingReady sets isSceneReady and enables aiming', () async {
    await controller.startSession();
    expect(controller.isSceneReady, isFalse);

    fake.emitScanProgress(0.4);
    await Future<void>.delayed(Duration.zero);
    expect(controller.scanProgress, closeTo(0.4, 1e-9));
    expect(controller.isSceneReady, isFalse);

    fake.emitTrackingReady();
    await Future<void>.delayed(Duration.zero);
    expect(controller.isSceneReady, isTrue);
    expect(controller.scanProgress, 1);
    expect(fake.aimingEnabled, isTrue);

    await controller.startSession();
    expect(controller.isSceneReady, isFalse);
    expect(controller.scanProgress, 0);
  });

  test('idle timeout pauses tracking when no points are set', () async {
    final idleController = ArMeasurementController(
      arService: fake,
      requestCameraPermission: () async => true,
      idleTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(idleController.dispose);

    await idleController.startSession();
    expect(idleController.isTrackingPaused, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(idleController.isTrackingPaused, isTrue);
    expect(fake.pauseCount, 1);

    await idleController.resumeTracking();
    expect(idleController.isTrackingPaused, isFalse);
    expect(fake.resumeCount, 1);
  });

  test('idle timeout does not pause after a pending start point', () async {
    final idleController = ArMeasurementController(
      arService: fake,
      requestCameraPermission: () async => true,
      idleTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(idleController.dispose);

    await idleController.startSession();
    fake.emitTrackingReady();
    await Future<void>.delayed(Duration.zero);
    fake.centerHit = point(0, 0, 0);
    await idleController.placePoint();
    expect(idleController.pendingStartPoint, isNotNull);

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(idleController.isTrackingPaused, isFalse);
    expect(fake.pauseCount, 0);
  });

  test('ensureReady timeout fails clearVisuals when not ready', () async {
    fake.ready = false;
    await expectLater(fake.clearVisuals(), throwsA(isA<TimeoutException>()));
  });
}
