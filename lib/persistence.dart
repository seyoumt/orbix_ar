/// Optional persistence helpers for AR Measurement.
///
/// ```dart
/// import 'package:ar_measurement/persistence.dart';
/// ```
///
/// Hosts can implement [MeasurementRecordStore] with their own backend, or use
/// the included [SqliteMeasurementRecordStore].
library;

export 'src/models/measurement_record.dart'
    show ARPoint, Measurement, LocationData, MeasurementRecord;
export 'src/persistence/measurement_record_store.dart';
export 'src/persistence/sqlite_measurement_record_store.dart';
