import 'package:ar_measurement/ar_measurement.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('MeasurementMath', () {
    test('euclidean distance between axis-aligned points', () {
      final a = ARPoint(
        x: 0,
        y: 0,
        z: 0,
        label: 'A',
        timestamp: DateTime(2026),
      );
      final b = ARPoint(
        x: 3,
        y: 4,
        z: 0,
        label: 'B',
        timestamp: DateTime(2026),
      );
      expect(MeasurementMath.distanceMeters(a, b), closeTo(5.0, 1e-9));
      expect(a.distanceTo(b), closeTo(5.0, 1e-9));
    });

    test('formats distance with ±7.5 cm margin', () {
      expect(MeasurementMath.formatDistance(1.0), '100.0 cm ±7.5 cm');
    });

    test('rotationAligningZTo is identity for +Z', () {
      final r = MeasurementMath.rotationAligningZTo(Vector3(0, 0, 2));
      expect(r.x, closeTo(0, 1e-6));
      expect(r.y, closeTo(0, 1e-6));
      expect(r.z, closeTo(0, 1e-6));
      expect(r.w, closeTo(1, 1e-6));
    });

    test('rotationAligningZTo maps +Z onto +X (Sceneform convention)', () {
      final r = MeasurementMath.rotationAligningZTo(Vector3(1, 0, 0));
      // 90° about +Y: (0, sin45, 0, cos45)
      expect(r.x, closeTo(0, 1e-5));
      expect(r.y, closeTo(0.70710678, 1e-5));
      expect(r.z, closeTo(0, 1e-5));
      expect(r.w, closeTo(0.70710678, 1e-5));

      // vector_math.Quaternion.rotated applies the inverse convention; Sceneform
      // uses q*v*q^-1, so validate with the conjugate here.
      final q = Quaternion(r.x, r.y, r.z, r.w);
      final sceneformStyle = Quaternion(
        -q.x,
        -q.y,
        -q.z,
        q.w,
      ).rotated(Vector3(0, 0, 1));
      expect(sceneformStyle.x, closeTo(1, 1e-5));
      expect(sceneformStyle.y, closeTo(0, 1e-5));
      expect(sceneformStyle.z, closeTo(0, 1e-5));
    });
  });

  group('Measurement', () {
    test('error margin is 7.5 cm', () {
      final now = DateTime.now();
      final m = Measurement(
        id: '1',
        name: 'test',
        startPoint: ARPoint(x: 0, y: 0, z: 0, label: 'A', timestamp: now),
        endPoint: ARPoint(x: 1, y: 0, z: 0, label: 'B', timestamp: now),
        distanceMeters: 1.0,
        createdAt: now,
      );
      expect(m.errorMarginMeters, 0.075);
      expect(m.distanceDisplay, contains('±7.5 cm'));
    });
  });

  group('MeasurementRecord', () {
    test('json round-trip', () {
      final now = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final record = MeasurementRecord(
        id: 'rec-1',
        createdAt: now,
        description: 'scene',
        status: 'draft',
        measurements: [
          Measurement(
            id: 'm1',
            name: 'Tire to curb',
            startPoint: ARPoint(
              x: 0,
              y: 0,
              z: 0,
              label: 'Tire',
              timestamp: now,
            ),
            endPoint: ARPoint(
              x: 0.5,
              y: 0,
              z: 0,
              label: 'Curb',
              timestamp: now,
            ),
            distanceMeters: 0.5,
            createdAt: now,
          ),
        ],
        location: LocationData(
          latitude: 1.0,
          longitude: 2.0,
          accuracy: 3.0,
          altitude: 4.0,
          timestamp: now,
        ),
      );

      final decoded = MeasurementRecord.fromJson(record.toJson());
      expect(decoded.id, record.id);
      expect(decoded.measurements.length, 1);
      expect(decoded.location!.latitude, 1.0);
      expect(decoded.measurements.first.distanceMeters, 0.5);
    });

    test('add and remove measurement', () {
      final now = DateTime.now();
      var record = MeasurementRecord(id: 'r', createdAt: now);
      final m = Measurement(
        id: 'm',
        name: 'n',
        startPoint: ARPoint(x: 0, y: 0, z: 0, label: 'A', timestamp: now),
        endPoint: ARPoint(x: 1, y: 0, z: 0, label: 'B', timestamp: now),
        distanceMeters: 1,
        createdAt: now,
      );
      record = record.addMeasurement(m);
      expect(record.totalMeasurements, 1);
      record = record.removeMeasurement('m');
      expect(record.totalMeasurements, 0);
    });
  });
}
