import 'package:vector_math/vector_math_64.dart';

import '../models/measurement_record.dart';

/// Pure measurement helpers (no Flutter / AR platform dependencies).
class MeasurementMath {
  MeasurementMath._();

  /// Default AR measurement error margin in meters (±7.5 cm).
  static const double defaultErrorMarginMeters = 0.075;

  /// Euclidean distance between two [ARPoint]s in meters.
  static double distanceMeters(ARPoint a, ARPoint b) => a.distanceTo(b);

  /// Human-readable distance with error margin.
  static String formatDistance(
    double distanceMeters, {
    double errorMarginMeters = defaultErrorMarginMeters,
  }) {
    final cm = (distanceMeters * 100).toStringAsFixed(1);
    final err = (errorMarginMeters * 100).toStringAsFixed(1);
    return '$cm cm ±$err cm';
  }

  /// Quaternion that rotates local +Z onto [direction] (for thin cube "lines").
  ///
  /// Returns `x,y,z,w` suitable for Sceneform / `ArCoreNode.rotation`.
  static Vector4 rotationAligningZTo(Vector3 direction) {
    final to = Vector3.copy(direction);
    if (to.length2 < 1e-12) {
      return Vector4(0, 0, 0, 1);
    }
    to.normalize();

    final from = Vector3(0, 0, 1);
    final q = Quaternion.fromTwoVectors(from, to);
    return Vector4(q.x, q.y, q.z, q.w);
  }
}
