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

/// Host-owned overlay — same tool HUD pattern as the package default,
/// with host wording ("Save") to show customization.
class _CustomOverlay extends StatelessWidget {
  const _CustomOverlay({required this.controller, required this.onComplete});

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
                  child: _ExampleHudChip(
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
                    child: _ExampleHudChip(
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
        if (!paused && (last != null || canComplete))
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: _ExampleHudChip(
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
                          child: const Text('Save'),
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

class _ExampleHudChip extends StatelessWidget {
  const _ExampleHudChip({required this.child, this.onTap});

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
