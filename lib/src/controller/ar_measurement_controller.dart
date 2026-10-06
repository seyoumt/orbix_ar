import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../ar/ar_service.dart';
import '../exceptions/ar_measurement_exception.dart';
import '../measurement/measurement_math.dart';
import '../models/measurement_record.dart';

const _uuid = Uuid();

/// Capture session phase for overlay UI.
enum CapturePhase {
  /// No active session.
  idle,

  /// Waiting for the start point (Place).
  awaitingStart,

  /// Start chosen; waiting for the end point (Place).
  awaitingEnd,

  /// At least one measurement; can complete.
  readyToComplete,
}

/// Session controller for AR collision measurement.
///
/// Storage-agnostic: [completeSession] returns an in-memory [MeasurementRecord].
/// Drive UI with [Listenable] / [ListenableBuilder], or embed [ArMeasurementView].
class ArMeasurementController extends ChangeNotifier {
  /// Creates a controller.
  ///
  /// [idleTimeout] controls how long an empty session may run before Android
  /// thermal pause (default 60s). Inject a short duration in tests.
  ArMeasurementController({
    ARService? arService,
    Logger? logger,
    Future<bool> Function()? requestCameraPermission,
    Duration idleTimeout = const Duration(seconds: 60),
  }) : _arService = arService ?? ARServiceFactory.createARService(),
       _logger = logger ?? Logger(),
       _requestCameraPermission =
           requestCameraPermission ?? _defaultRequestCameraPermission,
       _idleTimeout = idleTimeout;

  final ARService _arService;
  final Logger _logger;
  final Future<bool> Function() _requestCameraPermission;
  final Duration _idleTimeout;

  static Future<bool> _defaultRequestCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  MeasurementRecord? _activeRecord;
  ARPoint? _pendingStartPoint;
  String? _pendingMarkerId;
  String? _error;
  bool _isLoading = false;
  bool _isSupported = false;
  bool _isSceneReady = false;
  bool _isTrackingPaused = false;
  bool _aimValid = false;
  double? _previewDistanceMeters;
  double _scanProgress = 0;
  bool _initialized = false;
  bool _disposed = false;
  bool _pointHandling = false;
  Completer<void>? _initializeCompleter;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<void>? _trackingReadySub;
  StreamSubscription<double>? _scanProgressSub;
  StreamSubscription<bool>? _aimValidSub;
  StreamSubscription<double?>? _previewDistanceSub;
  Timer? _idleTimer;

  /// measurementId -> node ids in the AR scene
  final Map<String, List<String>> _visualNodes = {};

  /// Active draft record, or `null` when no session.
  MeasurementRecord? get activeRecord => _activeRecord;

  /// Measurements on the active session (empty when idle).
  List<Measurement> get measurements =>
      List.unmodifiable(_activeRecord?.measurements ?? const []);

  /// First placed start point awaiting an end point, if any.
  ARPoint? get pendingStartPoint => _pendingStartPoint;

  /// Last user-facing error message, if any.
  String? get error => _error;

  /// True while [initialize] is in progress.
  bool get isLoading => _isLoading;

  /// True after a successful support check.
  bool get isSupported => _isSupported;

  /// True once the look-around scan finished and placement can succeed.
  bool get isSceneReady => _isSceneReady;

  /// True when the camera was paused after idle with no points set.
  bool get isTrackingPaused => _isTrackingPaused;

  /// Look-around scan quality while coaching (`0.0`–`1.0`).
  double get scanProgress => _scanProgress;

  /// True when the center aim reticle is on a trackable plane.
  bool get aimValid => _aimValid;

  /// Live rubber-band length in meters while awaiting the end point, else `null`.
  double? get previewDistanceMeters => _previewDistanceMeters;

  /// True when the user can press Place (scene ready, aiming, not paused).
  bool get canPlace =>
      hasActiveSession &&
      _isSceneReady &&
      !_isTrackingPaused &&
      _aimValid &&
      !_pointHandling;

  /// Whether [startSession] has an open draft record.
  bool get hasActiveSession => _activeRecord != null;

  /// Number of completed measurements in the active session.
  int get measurementCount => _activeRecord?.measurements.length ?? 0;

  /// Underlying platform AR service (advanced / tests).
  ARService get arService => _arService;

  /// Eligible for thermal idle-pause (no points placed yet).
  bool get _canIdlePause =>
      hasActiveSession &&
      !_isTrackingPaused &&
      _pendingStartPoint == null &&
      measurementCount == 0;

  /// High-level capture UI phase.
  CapturePhase get phase {
    if (_activeRecord == null) return CapturePhase.idle;
    if (_pendingStartPoint != null) return CapturePhase.awaitingEnd;
    if (measurementCount > 0) return CapturePhase.readyToComplete;
    return CapturePhase.awaitingStart;
  }

  /// Initialize AR and check device support.
  Future<void> initialize() async {
    if (_disposed) return;
    if (_initialized) return;
    if (_initializeCompleter != null) {
      return _initializeCompleter!.future;
    }
    _initializeCompleter = Completer<void>();
    _isLoading = true;
    notifyListeners();
    try {
      final cameraGranted = await _requestCameraPermission();
      if (!cameraGranted) {
        throw ArMeasurementException(
          'Camera permission is required for AR capture.',
        );
      }

      await _arService.initialize();
      _isSupported = await _arService.isSupported();
      if (!_isSupported) {
        throw ArMeasurementException('AR is not supported on this device.');
      }
      await _errorSub?.cancel();
      _errorSub = _arService.platformErrorStream.listen(_onPlatformError);
      await _trackingReadySub?.cancel();
      _trackingReadySub = _arService.trackingReadyStream.listen(
        (_) => _onTrackingReady(),
      );
      await _scanProgressSub?.cancel();
      _scanProgressSub = _arService.scanProgressStream.listen(_onScanProgress);
      await _aimValidSub?.cancel();
      _aimValidSub = _arService.aimValidStream.listen(_onAimValid);
      await _previewDistanceSub?.cancel();
      _previewDistanceSub =
          _arService.previewDistanceStream.listen(_onPreviewDistance);
      _initialized = true;
      _error = null;
      _initializeCompleter!.complete();
    } catch (e, st) {
      _isSupported = false;
      _error = e is ArMeasurementException
          ? e.message
          : 'Failed to initialize AR: $e';
      _logger.e(_error, error: e, stackTrace: st);
      if (!_initializeCompleter!.isCompleted) {
        _initializeCompleter!.complete();
      }
    } finally {
      _isLoading = false;
      _initializeCompleter = null;
      if (!_disposed) notifyListeners();
    }
  }

  void _onPlatformError(String message) {
    if (_disposed) return;
    // Ignore spurious camera/session errors from the pause race.
    if (_isTrackingPaused) return;
    _error = message;
    notifyListeners();
  }

  void _onTrackingReady() {
    if (_disposed || _isSceneReady || _isTrackingPaused) return;
    _isSceneReady = true;
    _scanProgress = 1;
    unawaited(_syncAimingEnabled());
    notifyListeners();
  }

  void _onScanProgress(double value) {
    if (_disposed || _isSceneReady) return;
    final next = value.clamp(0.0, 1.0);
    if ((next - _scanProgress).abs() < 0.01) return;
    _scanProgress = next;
    notifyListeners();
  }

  void _onAimValid(bool valid) {
    if (_disposed || _aimValid == valid) return;
    _aimValid = valid;
    notifyListeners();
  }

  void _onPreviewDistance(double? meters) {
    if (_disposed) return;
    if (_previewDistanceMeters == meters) return;
    if (meters != null &&
        _previewDistanceMeters != null &&
        (meters - _previewDistanceMeters!).abs() < 0.002) {
      return;
    }
    _previewDistanceMeters = meters;
    notifyListeners();
  }

  Future<void> _syncMeasurePreview() async {
    if (_disposed) return;
    final start =
        _pendingStartPoint != null && hasActiveSession && !_isTrackingPaused
            ? _pendingStartPoint
            : null;
    try {
      await _arService.setMeasurePreviewStart(start);
    } catch (e, st) {
      _logger.w('setMeasurePreviewStart failed: $e', error: e, stackTrace: st);
    }
    if (start == null && _previewDistanceMeters != null) {
      _previewDistanceMeters = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _syncAimingEnabled() async {
    if (_disposed) return;
    final enabled =
        hasActiveSession && _isSceneReady && !_isTrackingPaused;
    try {
      await _arService.setAimingEnabled(enabled);
    } catch (e, st) {
      _logger.w('setAimingEnabled failed: $e', error: e, stackTrace: st);
    }
    if (!enabled && _aimValid) {
      _aimValid = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Place a point at the current center aim hit (start, then end).
  ///
  /// Returns `true` if a point was accepted.
  Future<bool> placePoint() async {
    if (_disposed ||
        _activeRecord == null ||
        _pointHandling ||
        _isTrackingPaused ||
        !_isSceneReady) {
      return false;
    }
    final point = await _arService.hitTestCenter();
    if (point == null) return false;
    await _handlePoint(point);
    return true;
  }

  Future<void> _handlePoint(ARPoint point) async {
    if (_pointHandling ||
        _disposed ||
        _activeRecord == null ||
        _isTrackingPaused) {
      return;
    }
    _pointHandling = true;
    try {
      if (_pendingStartPoint == null) {
        await _setPendingStart(point);
        return;
      }
      final start = _pendingStartPoint!;
      await addMeasurement(
        name: 'Measurement ${measurementCount + 1}',
        startPoint: start.copyWith(label: 'Point A'),
        endPoint: point.copyWith(label: 'Point B'),
      );
    } finally {
      _pointHandling = false;
    }
  }

  Future<void> _setPendingStart(ARPoint point) async {
    await _clearPendingMarker();
    if (_disposed) return;
    _pendingStartPoint = point;
    _pendingMarkerId = 'pending_start';
    _cancelIdleTimer();
    try {
      await _arService.showPointMarker(_pendingMarkerId!, point);
      await _syncMeasurePreview();
      _error = null;
    } catch (e, st) {
      _logger.e('Failed to show pending marker', error: e, stackTrace: st);
      _error = 'Failed to show marker: $e';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _clearPendingMarker() async {
    if (_pendingMarkerId != null) {
      try {
        await _arService.removeVisual(_pendingMarkerId!);
      } catch (_) {}
      _pendingMarkerId = null;
    }
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _resetIdleTimer() {
    _cancelIdleTimer();
    if (!_canIdlePause) return;
    _idleTimer = Timer(_idleTimeout, () {
      unawaited(_onIdleTimeout());
    });
  }

  Future<void> _onIdleTimeout() async {
    if (_disposed || !_canIdlePause) return;
    // Mark paused before native pause so a SessionPaused race is ignored.
    _isTrackingPaused = true;
    _isSceneReady = false;
    _scanProgress = 0;
    _error = null;
    _cancelIdleTimer();
    notifyListeners();
    await _syncAimingEnabled();
    try {
      await _arService.pauseTracking();
      if (_disposed) return;
    } catch (e, st) {
      _logger.e('Failed to pause tracking', error: e, stackTrace: st);
      if (_disposed) return;
      _isTrackingPaused = false;
      _resetIdleTimer();
      notifyListeners();
    }
  }

  /// Resume camera after an idle pause (or no-op if not paused).
  Future<void> resumeTracking() async {
    if (_disposed || !_isTrackingPaused) return;
    try {
      await _arService.resumeTracking();
      if (_disposed) return;
      _isTrackingPaused = false;
      _isSceneReady = false;
      _scanProgress = 0;
      _error = null;
      _resetIdleTimer();
      await _syncAimingEnabled();
      notifyListeners();
    } catch (e, st) {
      _error = 'Failed to resume camera: $e';
      _logger.e(_error, error: e, stackTrace: st);
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _ensureTrackingResumed() async {
    if (!_isTrackingPaused) return;
    try {
      await _arService.resumeTracking();
    } catch (_) {}
    _isTrackingPaused = false;
  }

  /// Start a new in-memory capture session.
  Future<void> startSession({LocationData? location}) async {
    await initialize();
    if (_disposed) return;
    if (!_isSupported) {
      _error = 'AR is not supported on this device.';
      notifyListeners();
      throw ArMeasurementException(_error!);
    }

    await _ensureTrackingResumed();
    _isSceneReady = false;
    _aimValid = false;
    _scanProgress = 0;
    await _syncAimingEnabled();
    try {
      await _arService.clearVisuals();
    } catch (e, st) {
      // Preview may still be attaching; retry after ready.
      _logger.w('clearVisuals on start deferred: $e', error: e, stackTrace: st);
      try {
        await _arService.ensureReady();
        await _arService.clearVisuals();
      } catch (_) {}
    }
    _visualNodes.clear();
    _activeRecord = MeasurementRecord(
      id: _uuid.v4(),
      createdAt: DateTime.now(),
      location: location,
      status: 'draft',
    );
    _pendingStartPoint = null;
    _pendingMarkerId = null;
    _previewDistanceMeters = null;
    await _syncMeasurePreview();
    _error = null;
    _resetIdleTimer();
    notifyListeners();
  }

  /// Discard the active session.
  Future<void> cancelSession() async {
    _cancelIdleTimer();
    await _clearPendingMarker();
    _pendingStartPoint = null;
    await _syncMeasurePreview();
    await _ensureTrackingResumed();
    try {
      await _arService.clearVisuals();
    } catch (_) {}
    _visualNodes.clear();
    _activeRecord = null;
    _isSceneReady = false;
    _aimValid = false;
    _scanProgress = 0;
    _previewDistanceMeters = null;
    await _syncAimingEnabled();
    _error = null;
    if (!_disposed) notifyListeners();
  }

  /// Clear the pending first point so the user can re-pick start.
  Future<void> clearPendingPoint() async {
    await _clearPendingMarker();
    _pendingStartPoint = null;
    await _syncMeasurePreview();
    _resetIdleTimer();
    if (!_disposed) notifyListeners();
  }

  /// Add a measurement between two labeled points and draw markers/line.
  Future<void> addMeasurement({
    required String name,
    required ARPoint startPoint,
    required ARPoint endPoint,
    String? notes,
  }) async {
    if (_activeRecord == null) {
      _error = 'No active session. Call startSession() first.';
      notifyListeners();
      throw ArMeasurementException(_error!);
    }

    try {
      await _clearPendingMarker();
      _pendingStartPoint = null;
      await _syncMeasurePreview();
      _cancelIdleTimer();

      final distance = MeasurementMath.distanceMeters(startPoint, endPoint);
      final measurement = Measurement(
        id: _uuid.v4(),
        name: name,
        startPoint: startPoint,
        endPoint: endPoint,
        distanceMeters: distance,
        notes: notes,
        createdAt: DateTime.now(),
      );

      final startId = '${measurement.id}_start';
      final endId = '${measurement.id}_end';
      final lineId = '${measurement.id}_line';

      await _arService.showPointMarker(startId, startPoint);
      await _arService.showPointMarker(endId, endPoint);
      await _arService.showMeasurementLine(lineId, startPoint, endPoint);

      _visualNodes[measurement.id] = [startId, endId, lineId];
      _activeRecord = _activeRecord!.addMeasurement(measurement);
      _error = null;
      if (!_disposed) notifyListeners();
    } catch (e, st) {
      _error = 'Failed to add measurement: $e';
      _logger.e(_error, error: e, stackTrace: st);
      if (!_disposed) notifyListeners();
      rethrow;
    }
  }

  /// Remove a measurement and its AR visuals.
  Future<void> removeMeasurement(String measurementId) async {
    if (_activeRecord == null) return;

    final nodes = _visualNodes.remove(measurementId) ?? const <String>[];
    for (final id in nodes) {
      try {
        await _arService.removeVisual(id);
      } catch (_) {}
    }
    _activeRecord = _activeRecord!.removeMeasurement(measurementId);
    _resetIdleTimer();
    if (!_disposed) notifyListeners();
  }

  /// Undo the last measurement (and clear a pending start point).
  Future<void> undoLastMeasurement() async {
    if (_pendingStartPoint != null) {
      await clearPendingPoint();
      return;
    }
    if (_activeRecord == null || _activeRecord!.measurements.isEmpty) return;
    final last = _activeRecord!.measurements.last;
    await removeMeasurement(last.id);
  }

  void setLocation(LocationData location) {
    if (_activeRecord == null) {
      _error = 'No active session.';
      notifyListeners();
      return;
    }
    _activeRecord = _activeRecord!.setLocation(location);
    notifyListeners();
  }

  void setDescription(String description) {
    if (_activeRecord == null) return;
    _activeRecord = _activeRecord!.copyWith(description: description);
    notifyListeners();
  }

  /// Completes the session and returns the record (status: completed).
  Future<MeasurementRecord> completeSession() async {
    if (_activeRecord == null) {
      throw ArMeasurementException('No active session to complete.');
    }
    if (_activeRecord!.measurements.isEmpty) {
      throw ArMeasurementException(
        'Cannot complete a session with no measurements.',
      );
    }

    _cancelIdleTimer();
    await _clearPendingMarker();
    _pendingStartPoint = null;
    await _syncMeasurePreview();
    await _ensureTrackingResumed();
    try {
      await _arService.clearVisuals();
    } catch (_) {}
    final record = _activeRecord!.copyWith(status: 'completed');
    _activeRecord = null;
    _isSceneReady = false;
    _aimValid = false;
    _scanProgress = 0;
    _previewDistanceMeters = null;
    await _syncAimingEnabled();
    _visualNodes.clear();
    _error = null;
    if (!_disposed) notifyListeners();
    return record;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelIdleTimer();
    unawaited(_errorSub?.cancel());
    unawaited(_trackingReadySub?.cancel());
    unawaited(_scanProgressSub?.cancel());
    unawaited(_aimValidSub?.cancel());
    unawaited(_previewDistanceSub?.cancel());
    unawaited(_arService.dispose());
    super.dispose();
  }
}
