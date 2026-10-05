/// Typed errors thrown by the AR collision measurement package.
class ArMeasurementException implements Exception {
  /// Creates an exception with a user-facing [message].
  ArMeasurementException(this.message, {this.cause});

  /// Human-readable error description.
  final String message;

  /// Optional underlying error.
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'ArMeasurementException: $message'
      : 'ArMeasurementException: $message ($cause)';
}
