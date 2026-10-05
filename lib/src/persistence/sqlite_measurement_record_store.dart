import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../models/measurement_record.dart';
import 'measurement_record_store.dart';

/// SQLite-backed [MeasurementRecordStore] for optional local history.
///
/// Hosts that use their own storage can ignore this class and implement
/// [MeasurementRecordStore] instead.
class SqliteMeasurementRecordStore implements MeasurementRecordStore {
  static const String _dbName = 'ar_measurement.db';
  static const int _dbVersion = 1;

  static const String _tableRecords = 'measurement_records';
  static const String _tableMeasurements = 'measurements';
  static const String _tableLocations = 'locations';

  late Database _db;
  final _logger = Logger();

  @override
  Future<void> initialize() async {
    try {
      final dbPath = await getDatabasesPath();
      final fullPath = path.join(dbPath, _dbName);

      _db = await openDatabase(
        fullPath,
        version: _dbVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onOpen: _onOpen,
      );

      _logger.i('Database initialized at $fullPath');
    } catch (e, stackTrace) {
      _logger.e(
        'Failed to initialize database',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Enable foreign key constraints (off by default in SQLite).
  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onOpen(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// Create database tables.
  Future<void> _onCreate(Database db, int version) async {
    _logger.i('Creating database tables (version $version)');

    await db.execute('''
      CREATE TABLE $_tableRecords (
        id TEXT PRIMARY KEY,
        createdAt TEXT NOT NULL,
        description TEXT,
        status TEXT NOT NULL,
        metadata TEXT,
        photoUrls TEXT,
        updatedAt TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tableMeasurements (
        id TEXT PRIMARY KEY,
        recordId TEXT NOT NULL,
        name TEXT NOT NULL,
        startPointX REAL NOT NULL,
        startPointY REAL NOT NULL,
        startPointZ REAL NOT NULL,
        startPointLabel TEXT NOT NULL,
        startPointTimestamp TEXT NOT NULL,
        endPointX REAL NOT NULL,
        endPointY REAL NOT NULL,
        endPointZ REAL NOT NULL,
        endPointLabel TEXT NOT NULL,
        endPointTimestamp TEXT NOT NULL,
        distanceMeters REAL NOT NULL,
        notes TEXT,
        createdAt TEXT NOT NULL,
        FOREIGN KEY (recordId) REFERENCES $_tableRecords(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tableLocations (
        id TEXT PRIMARY KEY,
        recordId TEXT NOT NULL UNIQUE,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        accuracy REAL NOT NULL,
        altitude REAL NOT NULL,
        timestamp TEXT NOT NULL,
        FOREIGN KEY (recordId) REFERENCES $_tableRecords(id) ON DELETE CASCADE
      )
    ''');

    _logger.i('Database tables created successfully');
  }

  /// Handle database upgrades.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    _logger.i('Upgrading database from v$oldVersion to v$newVersion');
    // Future versions can add schema migrations here.
  }

  @override
  Future<void> save(MeasurementRecord record) async {
    try {
      await _db.transaction((txn) async {
        await txn.insert(_tableRecords, {
          'id': record.id,
          'createdAt': record.createdAt.toIso8601String(),
          'description': record.description,
          'status': record.status,
          'metadata': record.metadata != null
              ? jsonEncode(record.metadata)
              : null,
          'photoUrls': jsonEncode(record.photoUrls),
          'updatedAt': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        // Replace children so removed measurements/location do not orphan.
        await txn.delete(
          _tableMeasurements,
          where: 'recordId = ?',
          whereArgs: [record.id],
        );
        await txn.delete(
          _tableLocations,
          where: 'recordId = ?',
          whereArgs: [record.id],
        );

        if (record.location != null) {
          await txn.insert(_tableLocations, {
            'id': '${record.id}_location',
            'recordId': record.id,
            'latitude': record.location!.latitude,
            'longitude': record.location!.longitude,
            'accuracy': record.location!.accuracy,
            'altitude': record.location!.altitude,
            'timestamp': record.location!.timestamp.toIso8601String(),
          });
        }

        for (final measurement in record.measurements) {
          await txn.insert(_tableMeasurements, {
            'id': measurement.id,
            'recordId': record.id,
            'name': measurement.name,
            'startPointX': measurement.startPoint.x,
            'startPointY': measurement.startPoint.y,
            'startPointZ': measurement.startPoint.z,
            'startPointLabel': measurement.startPoint.label,
            'startPointTimestamp': measurement.startPoint.timestamp
                .toIso8601String(),
            'endPointX': measurement.endPoint.x,
            'endPointY': measurement.endPoint.y,
            'endPointZ': measurement.endPoint.z,
            'endPointLabel': measurement.endPoint.label,
            'endPointTimestamp': measurement.endPoint.timestamp
                .toIso8601String(),
            'distanceMeters': measurement.distanceMeters,
            'notes': measurement.notes,
            'createdAt': measurement.createdAt.toIso8601String(),
          });
        }
      });

      _logger.i('Record saved: ${record.id}');
    } catch (e, stackTrace) {
      _logger.e('Failed to save record', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  @override
  Future<MeasurementRecord?> get(String recordId) async {
    try {
      final recordMaps = await _db.query(
        _tableRecords,
        where: 'id = ?',
        whereArgs: [recordId],
      );

      if (recordMaps.isEmpty) return null;

      return await _mapToRecord(recordMaps.first);
    } catch (e, stackTrace) {
      _logger.e('Failed to get record', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  @override
  Future<List<MeasurementRecord>> getAll() async {
    try {
      final recordMaps = await _db.query(_tableRecords);
      return await Future.wait(recordMaps.map(_mapToRecord));
    } catch (e, stackTrace) {
      _logger.e('Failed to get all records', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Map database row to [MeasurementRecord].
  Future<MeasurementRecord> _mapToRecord(Map<String, dynamic> map) async {
    final recordId = map['id'] as String;

    final locationMaps = await _db.query(
      _tableLocations,
      where: 'recordId = ?',
      whereArgs: [recordId],
    );

    LocationData? location;
    if (locationMaps.isNotEmpty) {
      final locMap = locationMaps.first;
      location = LocationData(
        latitude: (locMap['latitude'] as num).toDouble(),
        longitude: (locMap['longitude'] as num).toDouble(),
        accuracy: (locMap['accuracy'] as num).toDouble(),
        altitude: (locMap['altitude'] as num).toDouble(),
        timestamp: DateTime.parse(locMap['timestamp'] as String),
      );
    }

    final measurementMaps = await _db.query(
      _tableMeasurements,
      where: 'recordId = ?',
      whereArgs: [recordId],
    );

    final measurements = measurementMaps.map((m) {
      return Measurement(
        id: m['id'] as String,
        name: m['name'] as String,
        startPoint: ARPoint(
          x: (m['startPointX'] as num).toDouble(),
          y: (m['startPointY'] as num).toDouble(),
          z: (m['startPointZ'] as num).toDouble(),
          label: m['startPointLabel'] as String,
          timestamp: DateTime.parse(m['startPointTimestamp'] as String),
        ),
        endPoint: ARPoint(
          x: (m['endPointX'] as num).toDouble(),
          y: (m['endPointY'] as num).toDouble(),
          z: (m['endPointZ'] as num).toDouble(),
          label: m['endPointLabel'] as String,
          timestamp: DateTime.parse(m['endPointTimestamp'] as String),
        ),
        distanceMeters: (m['distanceMeters'] as num).toDouble(),
        notes: m['notes'] as String?,
        createdAt: DateTime.parse(m['createdAt'] as String),
      );
    }).toList();

    final metadata = map['metadata'] != null
        ? jsonDecode(map['metadata'] as String) as Map<String, dynamic>
        : null;

    final photoUrls = map['photoUrls'] != null
        ? (jsonDecode(map['photoUrls'] as String) as List).cast<String>()
        : <String>[];

    return MeasurementRecord(
      id: recordId,
      createdAt: DateTime.parse(map['createdAt'] as String),
      location: location,
      measurements: measurements,
      photoUrls: photoUrls,
      description: map['description'] as String?,
      status: map['status'] as String? ?? 'draft',
      metadata: metadata,
    );
  }

  @override
  Future<void> delete(String recordId) async {
    try {
      await _db.transaction((txn) async {
        await txn.delete(
          _tableMeasurements,
          where: 'recordId = ?',
          whereArgs: [recordId],
        );
        await txn.delete(
          _tableLocations,
          where: 'recordId = ?',
          whereArgs: [recordId],
        );
        await txn.delete(_tableRecords, where: 'id = ?', whereArgs: [recordId]);
      });
      _logger.i('Record deleted: $recordId');
    } catch (e, stackTrace) {
      _logger.e('Failed to delete record', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  @override
  Future<void> updateStatus(String recordId, String newStatus) async {
    try {
      await _db.update(
        _tableRecords,
        {'status': newStatus, 'updatedAt': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [recordId],
      );
      _logger.i('Record status updated: $recordId → $newStatus');
    } catch (e, stackTrace) {
      _logger.e(
        'Failed to update record status',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    await _db.close();
    _logger.i('Database closed');
  }
}
