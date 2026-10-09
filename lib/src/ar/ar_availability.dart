import 'dart:io' show Platform;

import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Result of an AR hardware / stack preflight check.
enum ArAvailabilityStatus {
  /// Device can attempt AR capture (ARCore / ARKit world tracking).
  supported,

  /// Device or platform cannot run this package's AR backends.
  unsupported,

  /// Availability could not be determined yet (rare after native retries).
  unknown,
}

/// Camera-free AR availability snapshot for host UI gating.
class ArAvailability {
  const ArAvailability({
    required this.status,
    this.message,
  });

  final ArAvailabilityStatus status;

  /// Short host-facing hint when not [isSupported].
  final String? message;

  /// True when [status] is [ArAvailabilityStatus.supported].
  bool get isSupported => status == ArAvailabilityStatus.supported;

  static const supported = ArAvailability(
    status: ArAvailabilityStatus.supported,
  );

  static const unsupportedPlatform = ArAvailability(
    status: ArAvailabilityStatus.unsupported,
    message: 'AR measurement is only available on Android and iOS.',
  );

  static const unsupportedDevice = ArAvailability(
    status: ArAvailabilityStatus.unsupported,
    message: 'This device does not support AR measurement.',
  );

  static const unknown = ArAvailability(
    status: ArAvailabilityStatus.unknown,
    message: 'AR availability could not be determined.',
  );
}

/// Public façade for package-level helpers (no controller / camera required).
class ArMeasurement {
  ArMeasurement._();

  static const _androidAvailabilityChannel = MethodChannel(
    'ar_measurement/availability',
  );

  /// Camera-free preflight: whether this device can run AR capture.
  ///
  /// Prefer this before navigating to [ArMeasurementView]. Still handle
  /// `onError` / `controller.isSupported` after init (permission, session).
  static Future<ArAvailability> checkAvailability() async {
    if (kIsWeb) {
      return ArAvailability.unsupportedPlatform;
    }
    try {
      if (Platform.isAndroid) {
        return await _checkAndroid();
      }
      if (Platform.isIOS) {
        return await _checkIos();
      }
    } catch (_) {
      return ArAvailability.unsupportedDevice;
    }
    return ArAvailability.unsupportedPlatform;
  }

  /// Convenience: `true` when [checkAvailability] reports supported.
  static Future<bool> isSupported() async {
    return (await checkAvailability()).isSupported;
  }

  static Future<ArAvailability> _checkAndroid() async {
    try {
      final result = await _androidAvailabilityChannel.invokeMethod<bool>(
        'isArCoreSupported',
      );
      if (result == true) return ArAvailability.supported;
      if (result == false) return ArAvailability.unsupportedDevice;
      return ArAvailability.unknown;
    } on MissingPluginException {
      return ArAvailability.unsupportedDevice;
    } on PlatformException {
      return ArAvailability.unsupportedDevice;
    }
  }

  static Future<ArAvailability> _checkIos() async {
    try {
      final ok = await ARKitPlugin.checkConfiguration(
        ARKitConfiguration.worldTracking,
      );
      return ok
          ? ArAvailability.supported
          : ArAvailability.unsupportedDevice;
    } catch (_) {
      return ArAvailability.unsupportedDevice;
    }
  }
}
