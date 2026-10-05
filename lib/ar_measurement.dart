/// AR Measurement — embeddable AR capture and measurement toolkit.
///
/// ```dart
/// import 'package:ar_measurement/ar_measurement.dart';
/// ```
///
/// For optional SQLite persistence:
///
/// ```dart
/// import 'package:ar_measurement/persistence.dart';
/// ```
library;

export 'src/ar/ar_service.dart' show ARService, ARServiceFactory;
export 'src/controller/ar_measurement_controller.dart'
    show ArMeasurementController, CapturePhase;
export 'src/exceptions/ar_measurement_exception.dart';
export 'src/measurement/measurement_math.dart';
export 'src/models/measurement_record.dart'
    show ARPoint, Measurement, LocationData, MeasurementRecord;
export 'src/widgets/ar_measurement_view.dart'
    show ArMeasurementView, ArMeasurementOverlayBuilder;
