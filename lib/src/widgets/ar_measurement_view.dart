import 'dart:io' show Platform;

import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../ar/ar_service.dart';
import '../controller/ar_measurement_controller.dart';
import '../models/measurement_record.dart';

/// Overlay builder for host chrome above the AR preview.
typedef ArMeasurementOverlayBuilder = Widget Function(
  BuildContext context,
  ArMeasurementController controller,
);

/// Embeddable AR capture view.
///
/// Mounts the platform AR preview and a default (or host) overlay driven by
/// [controller]. Requests camera permission and starts a session when
/// [autoStartSession] is true.
class ArMeasurementView extends StatefulWidget {
  /// Creates an [ArMeasurementView].
  const ArMeasurementView({
    super.key,
    required this.controller,
    this.overlayBuilder,
    this.onMeasurementAdded,
    this.onSessionCompleted,
    this.onError,
    this.autoStartSession = true,
    this.initialLocation,
  });

  /// Session / capture controller shared with the host.
  final ArMeasurementController controller;

  /// Optional host chrome; when null, the package default HUD is used.
  final ArMeasurementOverlayBuilder? overlayBuilder;

  /// Called when a new [Measurement] is added to the active session.
  final ValueChanged<Measurement>? onMeasurementAdded;

  /// Called after a successful [ArMeasurementController.completeSession].
  final ValueChanged<MeasurementRecord>? onSessionCompleted;

  /// Called for init failures and surfaced platform errors.
  final ValueChanged<Object>? onError;

  /// When true, calls [ArMeasurementController.startSession] after init.
  final bool autoStartSession;

  /// Optional GPS passed into [ArMeasurementController.startSession].
  final LocationData? initialLocation;

  @override
  State<ArMeasurementView> createState() => _ArMeasurementViewState();
}

class _ArMeasurementViewState extends State<ArMeasurementView> {
  int _lastMeasurementCount = 0;
  final GlobalKey _arPreviewKey = GlobalKey();
  Object? _reportedError;
  bool _bootstrapCancelled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void didUpdateWidget(covariant ArMeasurementView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastMeasurementCount = widget.controller.measurementCount;
      _reportedError = widget.controller.error;
    }
  }

  Future<void> _bootstrap() async {
    try {
      await widget.controller.initialize();
      if (_bootstrapCancelled || !mounted) return;
      if (widget.autoStartSession && !widget.controller.hasActiveSession) {
        await widget.controller.startSession(location: widget.initialLocation);
      }
    } catch (e) {
      if (!_bootstrapCancelled) {
        widget.onError?.call(e);
      }
    }
  }

  void _onControllerChanged() {
    final count = widget.controller.measurementCount;
    if (count > _lastMeasurementCount &&
        widget.controller.measurements.isNotEmpty) {
      widget.onMeasurementAdded?.call(widget.controller.measurements.last);
    }
    _lastMeasurementCount = count;

    final err = widget.controller.error;
    if (err != null && err != _reportedError) {
      _reportedError = err;
      widget.onError?.call(err);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _bootstrapCancelled = true;
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final showUnsupported =
        !controller.isSupported &&
        controller.error != null &&
        !controller.isLoading;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (controller.isSupported) _buildArPreview(),
        if (controller.isLoading && !controller.hasActiveSession)
          const ColoredBox(
            color: Color(0x88000000),
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white70,
                ),
              ),
            ),
          ),
        if (showUnsupported)
          ColoredBox(
            color: const Color(0xEE111111),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  controller.error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
                ),
              ),
            ),
          )
        else if (controller.isSupported && widget.overlayBuilder != null)
          widget.overlayBuilder!(context, controller)
        else if (controller.isSupported)
          _DefaultOverlay(
            controller: controller,
            onComplete: () async {
              try {
                final record = await controller.completeSession();
                widget.onSessionCompleted?.call(record);
              } catch (e) {
                widget.onError?.call(e);
              }
            },
          ),
      ],
    );
  }

  Widget _buildArPreview() {
    if (kIsWeb) {
      return const Center(child: Text('AR is not supported on web.'));
    }
    if (Platform.isAndroid) {
      return AndroidArBackend.createPreview(
        key: _arPreviewKey,
        service: widget.controller.arService,
      );
    }
    if (Platform.isIOS) {
      return ARKitSceneView(
        key: _arPreviewKey,
        enableTapRecognizer: true,
        planeDetection: ARPlaneDetection.horizontalAndVertical,
        onARKitViewCreated: (arkitController) {
          final service = widget.controller.arService;
          if (service is IOSARService) {
            service.setARKitController(arkitController);
          }
        },
      );
    }
    return const Center(
      child: Text('AR is only supported on Android and iOS.'),
    );
  }
}

class _DefaultOverlay extends StatelessWidget {
  const _DefaultOverlay({required this.controller, required this.onComplete});

  final ArMeasurementController controller;
  final VoidCallback onComplete;

  String get _instruction {
    if (controller.isTrackingPaused) return 'Paused — tap to resume';
    if (controller.hasActiveSession && !controller.isSceneReady) {
      return 'Move slowly to find a surface';
    }
    switch (controller.phase) {
      case CapturePhase.idle:
        return 'Starting…';
      case CapturePhase.awaitingStart:
        return 'Tap start point';
      case CapturePhase.awaitingEnd:
        return 'Tap end point';
      case CapturePhase.readyToComplete:
        return 'Tap to measure again';
    }
  }

  @override
  Widget build(BuildContext context) {
    final canUndo =
        !controller.isTrackingPaused &&
        (controller.pendingStartPoint != null ||
            controller.measurementCount > 0);
    final canComplete =
        !controller.isTrackingPaused && controller.measurementCount > 0;
    final scanning =
        controller.hasActiveSession &&
        !controller.isSceneReady &&
        !controller.isTrackingPaused;
    final paused = controller.isTrackingPaused;
    final last = controller.measurements.isEmpty
        ? null
        : controller.measurements.last;

    // Stack + positioned chrome so empty regions pass taps to the AR view.
    return Stack(
      fit: StackFit.expand,
      children: [
        if (paused)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => controller.resumeTracking(),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: const Center(
                  child: _HudChip(
                    child: Text(
                      'Tap to resume camera',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _HudChip(
                      onTap: paused ? () => controller.resumeTracking() : null,
                      child: Row(
                        children: [
                          if (scanning) ...[
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white70,
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: Text(
                              _instruction,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                height: 1.25,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (canUndo) ...[
                    const SizedBox(width: 8),
                    _HudIconButton(
                      tooltip: 'Undo',
                      icon: Icons.undo_rounded,
                      onPressed: () => controller.undoLastMeasurement(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (!paused && (last != null || canComplete))
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: _HudChip(
                  child: Row(
                    children: [
                      Expanded(
                        child: last == null
                            ? const SizedBox.shrink()
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    last.distanceDisplay,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                  if (controller.measurementCount > 1)
                                    Text(
                                      '${controller.measurementCount} measurements',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.7,
                                        ),
                                        fontSize: 12,
                                      ),
                                    ),
                                ],
                              ),
                      ),
                      if (canComplete)
                        TextButton(
                          onPressed: onComplete,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          child: const Text('Done'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Compact translucent HUD surface — stays out of the way of the camera.
class _HudChip extends StatelessWidget {
  const _HudChip({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: child,
        ),
      ),
    );
  }
}

class _HudIconButton extends StatelessWidget {
  const _HudIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(10),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white, size: 22),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      ),
    );
  }
}
