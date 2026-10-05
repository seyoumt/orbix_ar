import 'dart:math';

import 'package:json_annotation/json_annotation.dart';

part 'measurement_record.g.dart';

/// A 3D point in AR world space.
@JsonSerializable()
class ARPoint {
  /// World X coordinate in meters.
  final double x;

  /// World Y coordinate in meters.
  final double y;

  /// World Z coordinate in meters.
  final double z;

  /// Optional human label (e.g. "Tire FL").
  final String label;

  /// When this point was captured.
  final DateTime timestamp;

  /// Optional platform plane / anchor id.
  final String? planeId;

  /// Creates an [ARPoint].
  ARPoint({
    required this.x,
    required this.y,
    required this.z,
    this.label = '',
    required this.timestamp,
    this.planeId,
  });

  /// Deserializes from JSON.
  factory ARPoint.fromJson(Map<String, dynamic> json) =>
      _$ARPointFromJson(json);

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => _$ARPointToJson(this);

  /// Returns a copy with selected fields replaced.
  ARPoint copyWith({
    double? x,
    double? y,
    double? z,
    String? label,
    DateTime? timestamp,
    String? planeId,
  }) {
    return ARPoint(
      x: x ?? this.x,
      y: y ?? this.y,
      z: z ?? this.z,
      label: label ?? this.label,
      timestamp: timestamp ?? this.timestamp,
      planeId: planeId ?? this.planeId,
    );
  }

  /// Euclidean distance to [other] in meters.
  double distanceTo(ARPoint other) {
    final dx = x - other.x;
    final dy = y - other.y;
    final dz = z - other.z;
    return sqrt(dx * dx + dy * dy + dz * dz);
  }

  @override
  String toString() => 'ARPoint($label: x=$x, y=$y, z=$z)';
}

/// A distance measurement between two [ARPoint]s.
@JsonSerializable(explicitToJson: true)
class Measurement {
  /// Unique measurement id.
  final String id;

  /// Display name (e.g. "Tire FL to Lane Marker").
  final String name;

  /// First endpoint.
  final ARPoint startPoint;

  /// Second endpoint.
  final ARPoint endPoint;

  /// Stored distance in meters.
  final double distanceMeters;

  /// Optional free-form notes.
  final String? notes;

  /// When this measurement was created.
  final DateTime createdAt;

  /// Creates a [Measurement].
  Measurement({
    required this.id,
    required this.name,
    required this.startPoint,
    required this.endPoint,
    required this.distanceMeters,
    this.notes,
    required this.createdAt,
  });

  /// Fixed estimated error margin (±7.5 cm).
  double get errorMarginMeters => 0.075;

  /// Human-readable distance including the error margin.
  String get distanceDisplay =>
      '${(distanceMeters * 100).toStringAsFixed(1)} cm ±${(errorMarginMeters * 100).toStringAsFixed(1)} cm';

  /// Deserializes from JSON.
  factory Measurement.fromJson(Map<String, dynamic> json) =>
      _$MeasurementFromJson(json);

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => _$MeasurementToJson(this);

  @override
  String toString() => 'Measurement($name: $distanceDisplay)';
}

/// Optional GPS location attached to a [MeasurementRecord].
@JsonSerializable()
class LocationData {
  /// Latitude in degrees.
  final double latitude;

  /// Longitude in degrees.
  final double longitude;

  /// Reported GPS accuracy in meters.
  final double accuracy;

  /// Altitude in meters.
  final double altitude;

  /// When the fix was taken.
  final DateTime timestamp;

  /// Creates [LocationData].
  LocationData({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.altitude,
    required this.timestamp,
  });

  /// Deserializes from JSON.
  factory LocationData.fromJson(Map<String, dynamic> json) =>
      _$LocationDataFromJson(json);

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => _$LocationDataToJson(this);

  @override
  String toString() =>
      'LocationData(lat=$latitude, lon=$longitude, accuracy=${accuracy}m)';
}

/// One capture session: measurements, optional GPS, and metadata.
@JsonSerializable(explicitToJson: true)
class MeasurementRecord {
  /// Unique record id.
  final String id;

  /// When the session was created.
  final DateTime createdAt;

  /// Optional GPS fix from the host.
  final LocationData? location;

  /// Measured segments in this session.
  final List<Measurement> measurements;

  /// Local photo paths (host-managed; may be empty).
  final List<String> photoUrls;

  /// Optional scene description / notes.
  final String? description;

  /// Lifecycle status (`draft`, `completed`, `submitted`, …).
  final String status;

  /// Host-defined extra fields.
  final Map<String, dynamic>? metadata;

  /// Creates a [MeasurementRecord].
  MeasurementRecord({
    required this.id,
    required this.createdAt,
    this.location,
    this.measurements = const [],
    this.photoUrls = const [],
    this.description,
    this.status = 'draft',
    this.metadata,
  });

  /// Deserializes from JSON.
  factory MeasurementRecord.fromJson(Map<String, dynamic> json) =>
      _$MeasurementRecordFromJson(json);

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => _$MeasurementRecordToJson(this);

  /// Returns a copy with selected fields replaced.
  MeasurementRecord copyWith({
    String? id,
    DateTime? createdAt,
    LocationData? location,
    List<Measurement>? measurements,
    List<String>? photoUrls,
    String? description,
    String? status,
    Map<String, dynamic>? metadata,
  }) {
    return MeasurementRecord(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      location: location ?? this.location,
      measurements: measurements ?? this.measurements,
      photoUrls: photoUrls ?? this.photoUrls,
      description: description ?? this.description,
      status: status ?? this.status,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Appends [measurement] and returns a new record.
  MeasurementRecord addMeasurement(Measurement measurement) {
    return copyWith(measurements: [...measurements, measurement]);
  }

  /// Removes the measurement with [measurementId].
  MeasurementRecord removeMeasurement(String measurementId) {
    return copyWith(
      measurements: measurements.where((m) => m.id != measurementId).toList(),
    );
  }

  /// Sets [location] on a copy of this record.
  MeasurementRecord setLocation(LocationData newLocation) {
    return copyWith(location: newLocation);
  }

  /// Number of measurements.
  int get totalMeasurements => measurements.length;

  /// Number of photo paths.
  int get totalPhotos => photoUrls.length;

  /// Mean of [Measurement.distanceMeters], or `0` if empty.
  double get averageDistanceMeters => measurements.isEmpty
      ? 0
      : measurements.fold<double>(0, (sum, m) => sum + m.distanceMeters) /
            measurements.length;

  @override
  String toString() =>
      'MeasurementRecord(id=$id, measurements=${measurements.length}, photos=${photoUrls.length})';
}
