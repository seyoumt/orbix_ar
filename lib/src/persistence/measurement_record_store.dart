import '../models/measurement_record.dart';

/// Persistence contract for collision records.
///
/// Hosts may implement this with Drift, Hive, Firebase, etc.
abstract class MeasurementRecordStore {
  /// Open / prepare the store (no-op for some backends).
  Future<void> initialize();

  /// Insert or replace a record.
  Future<void> save(MeasurementRecord record);

  /// Fetch a single record by [id], or `null` if missing.
  Future<MeasurementRecord?> get(String id);

  /// Fetch all stored records.
  Future<List<MeasurementRecord>> getAll();

  /// Delete a record and related children.
  Future<void> delete(String id);

  /// Update only the status field.
  Future<void> updateStatus(String id, String status);

  /// Release resources.
  Future<void> close();
}
