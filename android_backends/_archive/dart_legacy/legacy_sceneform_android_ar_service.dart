import 'dart:async';
import 'dart:math' as math;

import 'package:arcore_flutter_plugin/arcore_flutter_plugin.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

import '../../measurement/measurement_math.dart';
import '../../models/measurement_record.dart';
import '../ar_service.dart';

/// Legacy Android AR via vendored Sceneform plugin (Virtual Display).
class LegacySceneformAndroidArService implements ARService {
  ArCoreController? _arCoreController;
  final _logger = Logger();
  final _pointDetectionController = StreamController<ARPoint>.broadcast();
  final _planeDetectionController = StreamController<ARPlane>.broadcast();
  final Set<String> _nodeIds = {};

  @override
  Future<void> initialize() async {
    _logger.i('Initializing LegacySceneformAndroidArService');
  }

  void setARCoreController(ArCoreController controller) {
    _arCoreController = controller;
    _setupARCoreListeners();
  }

  void _setupARCoreListeners() {
    final controller = _arCoreController;
    if (controller == null) return;

    controller.onPlaneDetected = (ArCorePlane plane) {
      final translation = plane.centerPose?.translation;
      _planeDetectionController.add(
        ARPlane(
          id: translation != null
              ? '${translation.x}_${translation.y}_${translation.z}'
              : DateTime.now().millisecondsSinceEpoch.toString(),
          extentX: plane.extendX ?? 0,
          extentZ: plane.extendZ ?? 0,
          detectedAt: DateTime.now(),
          alignment: plane.type == ArCorePlaneType.VERTICAL
              ? 'vertical'
              : 'horizontal',
        ),
      );
    };

    controller.onPlaneTap = (List<ArCoreHitTestResult> hits) {
      if (hits.isEmpty) return;
      final translation = hits.first.pose.translation;
      _pointDetectionController.add(
        ARPoint(
          x: translation.x,
          y: translation.y,
          z: translation.z,
          label: 'tap',
          timestamp: DateTime.now(),
        ),
      );
    };

    _logger.i('Legacy ARCore listeners configured');
  }

  @override
  Stream<ARPoint> get pointDetectionStream => _pointDetectionController.stream;

  @override
  Stream<ARPlane> get planeDetectionStream => _planeDetectionController.stream;

  @override
  Future<void> showPointMarker(String nodeId, ARPoint point) async {
    final controller = _arCoreController;
    if (controller == null) return;

    final material = ArCoreMaterial(color: Colors.blueAccent, metallic: 0.0);
    final sphere = ArCoreSphere(radius: 0.015, materials: [material]);
    final node = ArCoreNode(
      name: nodeId,
      shape: sphere,
      position: vector.Vector3(point.x, point.y, point.z),
    );
    await controller.addArCoreNode(node);
    _nodeIds.add(nodeId);
  }

  @override
  Future<void> showMeasurementLine(
    String nodeId,
    ARPoint start,
    ARPoint end,
  ) async {
    final controller = _arCoreController;
    if (controller == null) return;

    final dx = end.x - start.x;
    final dy = end.y - start.y;
    final dz = end.z - start.z;
    final length = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (length < 1e-6) return;

    final mid = vector.Vector3(
      (start.x + end.x) / 2,
      (start.y + end.y) / 2,
      (start.z + end.z) / 2,
    );
    final direction = vector.Vector3(dx, dy, dz);
    final rotation = MeasurementMath.rotationAligningZTo(direction);

    final material = ArCoreMaterial(color: Colors.yellowAccent, metallic: 0.0);
    final cube = ArCoreCube(
      size: vector.Vector3(0.005, 0.005, length),
      materials: [material],
    );
    final node = ArCoreNode(
      name: nodeId,
      shape: cube,
      position: mid,
      rotation: rotation,
    );
    await controller.addArCoreNode(node);
    _nodeIds.add(nodeId);
  }

  @override
  Future<void> removeVisual(String nodeId) async {
    final controller = _arCoreController;
    if (controller == null) return;
    await controller.removeNode(nodeName: nodeId);
    _nodeIds.remove(nodeId);
  }

  @override
  Future<void> clearVisuals() async {
    for (final id in List<String>.from(_nodeIds)) {
      await removeVisual(id);
    }
  }

  @override
  Future<void> dispose() async {
    await clearVisuals();
    _arCoreController?.dispose();
    _arCoreController = null;
    await _pointDetectionController.close();
    await _planeDetectionController.close();
  }

  @override
  Future<bool> isSupported() async {
    final available = await ArCoreController.checkArCoreAvailability();
    return available == true;
  }
}

/// Back-compat typedef used by older call sites / tests.
typedef AndroidARService = LegacySceneformAndroidArService;
