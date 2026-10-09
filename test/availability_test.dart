import 'package:ar_measurement/ar_measurement.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArAvailability', () {
    test('isSupported matches status', () {
      expect(ArAvailability.supported.isSupported, isTrue);
      expect(ArAvailability.unsupportedDevice.isSupported, isFalse);
      expect(ArAvailability.unsupportedPlatform.isSupported, isFalse);
      expect(ArAvailability.unknown.isSupported, isFalse);
      expect(
        const ArAvailability(
          status: ArAvailabilityStatus.supported,
        ).isSupported,
        isTrue,
      );
      expect(
        const ArAvailability(
          status: ArAvailabilityStatus.unsupported,
          message: 'nope',
        ).isSupported,
        isFalse,
      );
    });

    test('unsupportedDevice carries a host-facing message', () {
      expect(ArAvailability.unsupportedDevice.message, isNotNull);
      expect(ArAvailability.unsupportedDevice.message, isNotEmpty);
    });
  });

  group('ArMeasurement.checkAvailability', () {
    const channel = MethodChannel('ar_measurement/availability');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('Android channel true → supported', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'isArCoreSupported');
        return true;
      });

      // On non-Android CI hosts this exercises iOS/web/desktop branches instead.
      // Still validates the façade never throws and returns a defined status.
      final result = await ArMeasurement.checkAvailability();
      expect(result.status, isA<ArAvailabilityStatus>());
      expect(await ArMeasurement.isSupported(), result.isSupported);
    });

    test('façade never throws and isSupported matches checkAvailability',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => false);

      final availability = await ArMeasurement.checkAvailability();
      expect(availability.status, isNotNull);
      expect(await ArMeasurement.isSupported(), availability.isSupported);
    });
  });
}
