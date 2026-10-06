import 'package:ar_measurement/ar_measurement.dart';
import 'package:ar_measurement/persistence.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Measurement Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3D4F5F),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _store = SqliteMeasurementRecordStore();
  List<MeasurementRecord> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _loading = true);
    try {
      await _store.initialize();
      _history = await _store.getAll();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<LocationData?> _currentLocation() async {
    try {
      final permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition();
      return LocationData(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracy: pos.accuracy,
        altitude: pos.altitude,
        timestamp: pos.timestamp,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _openCapture({required bool customOverlay}) async {
    final location = await _currentLocation();
    if (!mounted) return;

    final record = await Navigator.of(context).push<MeasurementRecord>(
      MaterialPageRoute(
        builder: (_) => CaptureScreen(
          customOverlay: customOverlay,
          initialLocation: location,
        ),
      ),
    );

    if (record != null) {
      await _store.save(record);
      await _loadHistory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved ${record.measurements.length} measurement(s)'),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _store.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: const Text('AR Measurement'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          Text(
            'Capture',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Needs a physical ARCore / ARKit device. '
            'Errors surface via onError — not as an empty success.',
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => _openCapture(customOverlay: false),
            child: const Text('Start capture'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _openCapture(customOverlay: true),
            child: const Text('Start with custom overlay'),
          ),
          const SizedBox(height: 28),
          Text(
            'History',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            )
          else if (_history.isEmpty)
            Text(
              'No saved records yet.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            )
          else
            ..._history.map((r) {
              final title = r.description?.trim().isNotEmpty == true
                  ? r.description!
                  : 'Record ${r.id.substring(0, 8)}';
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(title),
                  subtitle: Text(
                    '${r.measurements.length} measurement(s) · ${r.status}',
                    style: TextStyle(color: muted),
                  ),
                  trailing: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await _store.delete(r.id);
                      await _loadHistory();
                    },
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    super.key,
    required this.customOverlay,
    this.initialLocation,
  });

  final bool customOverlay;
  final LocationData? initialLocation;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  late final ArMeasurementController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ArMeasurementController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    try {
      final record = await _controller.completeSession();
      if (mounted) Navigator.of(context).pop(record);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _ExampleHudIconButton(
                  tooltip: 'Back',
                  icon: Icons.arrow_back_rounded,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ),
          Expanded(
            child: ArMeasurementView(
              controller: _controller,
              initialLocation: widget.initialLocation,
              onSessionCompleted: (record) => Navigator.of(context).pop(record),
              onError: (e) {
                if (!mounted) return;
                final scheme = Theme.of(context).colorScheme;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('AR unavailable: $e'),
                    backgroundColor: scheme.error,
                  ),
                );
              },
              overlayBuilder: widget.customOverlay
                  ? (context, controller) => _CustomOverlay(
                      controller: controller,
                      onComplete: _complete,
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Host-owned overlay — same reticle/Place flow as the package default,
/// with host wording ("Save") to show customization.
class _CustomOverlay extends StatelessWidget {
  const _CustomOverlay({required this.controller, required this.onComplete});

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
        return 'Place again for another segment, or Save';
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
    final measuring =
        controller.hasActiveSession &&
        controller.isSceneReady &&
        !controller.isTrackingPaused;
    final paused = controller.isTrackingPaused;
    final last = controller.measurements.isEmpty
        ? null
        : controller.measurements.last;

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
        if (scanning)
          Positioned.fill(
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
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: 220,
                          child: LinearProgressIndicator(
                            value: controller.scanProgress <= 0
                                ? null
                                : controller.scanProgress.clamp(0.0, 1.0),
                            minHeight: 6,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.2,
                            ),
                            color: const Color(0xFFF5C518),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
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
                      child: _ExampleHudChip(
                        child: Text(
                          _measureInstruction,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    if (canUndo) ...[
                      const SizedBox(width: 8),
                      _ExampleHudIconButton(
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
          if (last != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 108,
              child: SafeArea(
                top: false,
                child: Center(
                  child: Material(
                    color: const Color(0xFFF5C518),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(
                        'Length=${(last.distanceMeters * 100).round()} cm',
                        style: const TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
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
                        child: const Text('Save'),
                      )
                    else
                      const SizedBox(width: 64),
                    const Spacer(),
                    Material(
                      color: controller.canPlace
                          ? const Color(0xFFF5C518)
                          : Colors.white.withValues(alpha: 0.25),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: controller.canPlace
                            ? () => controller.placePoint()
                            : null,
                        child: SizedBox(
                          width: 72,
                          height: 72,
                          child: Icon(
                            Icons.add_rounded,
                            size: 36,
                            color: controller.canPlace
                                ? Colors.black87
                                : Colors.white54,
                          ),
                        ),
                      ),
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

class _ExampleHudChip extends StatelessWidget {
  const _ExampleHudChip({required this.child});

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

class _ExampleHudIconButton extends StatelessWidget {
  const _ExampleHudIconButton({
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
