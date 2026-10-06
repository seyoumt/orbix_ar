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
        enableTapRecognizer: false,
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

  String get _measureInstruction {
    switch (controller.phase) {
      case CapturePhase.idle:
        return 'Starting…';
      case CapturePhase.awaitingStart:
        return 'Aim at the start point, then Place';
      case CapturePhase.awaitingEnd:
        return 'Aim at the end point, then Place';
      case CapturePhase.readyToComplete:
        return 'Place again for another segment, or Done';
    }
  }

  String _lengthLabelMeters(double meters) {
    final cm = (meters * 100).round();
    return 'Length $cm cm';
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
    final measuring =
        controller.hasActiveSession &&
        controller.isSceneReady &&
        !controller.isTrackingPaused;
    final paused = controller.isTrackingPaused;
    final last = controller.measurements.isEmpty
        ? null
        : controller.measurements.last;
    final previewMeters = controller.previewDistanceMeters;
    final showLivePreview =
        controller.phase == CapturePhase.awaitingEnd && previewMeters != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (paused)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.35),
              child: Center(
                child: FilledButton.tonal(
                  onPressed: () => controller.resumeTracking(),
                  child: const Text('Resume camera'),
                ),
              ),
            ),
          ),
        if (scanning) _ScanCoachingPanel(progress: controller.scanProgress),
        if (measuring) ...[
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: _HudChip(
                        child: Text(
                          _measureInstruction,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            height: 1.25,
                          ),
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
          if (showLivePreview || last != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 108,
              child: SafeArea(
                top: false,
                child: Center(
                  child: showLivePreview
                      ? _LengthChip(
                          label: _lengthLabelMeters(previewMeters),
                          live: true,
                        )
                      : _LengthChip(
                          label: _lengthLabelMeters(last!.distanceMeters),
                          onDelete: canUndo
                              ? () => controller.undoLastMeasurement()
                              : null,
                        ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Row(
                  children: [
                    if (canComplete)
                      TextButton(
                        onPressed: onComplete,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: Colors.black.withValues(alpha: 0.45),
                        ),
                        child: const Text('Done'),
                      )
                    else
                      const SizedBox(width: 64),
                    const Spacer(),
                    _PlaceButton(
                      enabled: controller.canPlace,
                      onPressed: () => controller.placePoint(),
                    ),
                    const Spacer(),
                    const SizedBox(width: 64),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Dedicated scan coaching — shown until look-around scan completes.
class _ScanCoachingPanel extends StatelessWidget {
  const _ScanCoachingPanel({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final pct = (progress.clamp(0.0, 1.0) * 100).round();
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.28),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.phonelink_setup_rounded,
                    size: 72,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Move around to scan the area',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Look left, right, and across floors/walls so surfaces '
                    'are mapped before measuring.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.82),
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 22),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      width: 220,
                      child: LinearProgressIndicator(
                        value: progress <= 0 ? null : progress.clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        color: const Color(0xFFF5C518),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    progress <= 0 ? 'Detecting surfaces…' : 'Scanning… $pct%',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaceButton extends StatelessWidget {
  const _PlaceButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: enabled
            ? const Color(0xFFF5C518)
            : Colors.white.withValues(alpha: 0.22),
        shape: const CircleBorder(),
        elevation: enabled ? 6 : 0,
        shadowColor: const Color(0xAAF5C518),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            width: 76,
            height: 76,
            child: Icon(
              Icons.add_rounded,
              size: 38,
              color: enabled ? const Color(0xFF1A1A1A) : Colors.white54,
            ),
          ),
        ),
      ),
    );
  }
}

class _LengthChip extends StatelessWidget {
  const _LengthChip({
    required this.label,
    this.onDelete,
    this.live = false,
  });

  final String label;
  final VoidCallback? onDelete;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: live ? const Color(0xE6F5C518) : const Color(0xFFF5C518),
      borderRadius: BorderRadius.circular(10),
      elevation: live ? 2 : 0,
      shadowColor: const Color(0x66F5C518),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (live) ...[
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: Color(0xFF1A1A1A),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF1A1A1A),
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            if (onDelete != null) ...[
              const SizedBox(width: 6),
              InkWell(
                onTap: onDelete,
                child: const Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: Color(0xFF1A1A1A),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact translucent HUD surface — stays out of the way of the camera.
class _HudChip extends StatelessWidget {
  const _HudChip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: child,
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
