// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'measurement_record.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ARPoint _$ARPointFromJson(Map<String, dynamic> json) => ARPoint(
  x: (json['x'] as num).toDouble(),
  y: (json['y'] as num).toDouble(),
  z: (json['z'] as num).toDouble(),
  label: json['label'] as String? ?? '',
  timestamp: DateTime.parse(json['timestamp'] as String),
  planeId: json['planeId'] as String?,
);

Map<String, dynamic> _$ARPointToJson(ARPoint instance) => <String, dynamic>{
  'x': instance.x,
  'y': instance.y,
  'z': instance.z,
  'label': instance.label,
  'timestamp': instance.timestamp.toIso8601String(),
  'planeId': instance.planeId,
};

Measurement _$MeasurementFromJson(Map<String, dynamic> json) => Measurement(
  id: json['id'] as String,
  name: json['name'] as String,
  startPoint: ARPoint.fromJson(json['startPoint'] as Map<String, dynamic>),
  endPoint: ARPoint.fromJson(json['endPoint'] as Map<String, dynamic>),
  distanceMeters: (json['distanceMeters'] as num).toDouble(),
  notes: json['notes'] as String?,
  createdAt: DateTime.parse(json['createdAt'] as String),
);

Map<String, dynamic> _$MeasurementToJson(Measurement instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'startPoint': instance.startPoint.toJson(),
      'endPoint': instance.endPoint.toJson(),
      'distanceMeters': instance.distanceMeters,
      'notes': instance.notes,
      'createdAt': instance.createdAt.toIso8601String(),
    };

LocationData _$LocationDataFromJson(Map<String, dynamic> json) => LocationData(
  latitude: (json['latitude'] as num).toDouble(),
  longitude: (json['longitude'] as num).toDouble(),
  accuracy: (json['accuracy'] as num).toDouble(),
  altitude: (json['altitude'] as num).toDouble(),
  timestamp: DateTime.parse(json['timestamp'] as String),
);

Map<String, dynamic> _$LocationDataToJson(LocationData instance) =>
    <String, dynamic>{
      'latitude': instance.latitude,
      'longitude': instance.longitude,
      'accuracy': instance.accuracy,
      'altitude': instance.altitude,
      'timestamp': instance.timestamp.toIso8601String(),
    };

MeasurementRecord _$MeasurementRecordFromJson(Map<String, dynamic> json) =>
    MeasurementRecord(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      location: json['location'] == null
          ? null
          : LocationData.fromJson(json['location'] as Map<String, dynamic>),
      measurements:
          (json['measurements'] as List<dynamic>?)
              ?.map((e) => Measurement.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      photoUrls:
          (json['photoUrls'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      description: json['description'] as String?,
      status: json['status'] as String? ?? 'draft',
      metadata: json['metadata'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$MeasurementRecordToJson(MeasurementRecord instance) =>
    <String, dynamic>{
      'id': instance.id,
      'createdAt': instance.createdAt.toIso8601String(),
      'location': instance.location?.toJson(),
      'measurements': instance.measurements.map((e) => e.toJson()).toList(),
      'photoUrls': instance.photoUrls,
      'description': instance.description,
      'status': instance.status,
      'metadata': instance.metadata,
    };
