import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/device_config_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_device_config_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_geo_country_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/sdk/device_country_config_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('DeviceCountryConfigController.ensure', () {
    test('applies the target region, reboots, and verifies adoption', () async {
      final env = _Env(); // device on EU868(3); country US -> US915(1)
      final controller = env.build();

      final status = await controller.ensure(reason: 'startup');

      expect(status.outcome, DeviceCountryConfigOutcome.applied);
      expect(status.countryIso, 'US');
      expect(status.targetRegion, LoraRegionCode.us915);
      expect(env.setRegionCalls, <int>[LoraRegionCode.us915.wireValue]);
      expect(env.rebootCalls, 1);
      final record = await env.store.getRecord('hw-1');
      expect(record!.applied, isTrue);
      expect(record.region, LoraRegionCode.us915);
    });

    test('skips (up to date) when the device already runs the region',
        () async {
      final env = _Env()..reportedRegion = LoraRegionCode.us915.wireValue;
      final controller = env.build();

      final status = await controller.ensure();

      expect(status.outcome, DeviceCountryConfigOutcome.skippedUpToDate);
      expect(env.setRegionCalls, isEmpty);
      expect(env.rebootCalls, 0);
    });

    test('never reboots while a safety flow is active', () async {
      final env = _Env()..safetyReason = 'SOS flow active';
      final controller = env.build();

      final status = await controller.ensure();

      expect(status.outcome, DeviceCountryConfigOutcome.skippedSafetyActive);
      expect(status.detail, 'SOS flow active');
      expect(env.setRegionCalls, isEmpty);
      expect(env.rebootCalls, 0);
    });

    test('skips when no command-capable device is connected', () async {
      final env = _Env()..device = null;
      final controller = env.build();

      final status = await controller.ensure();

      expect(status.outcome, DeviceCountryConfigOutcome.skippedDeviceOffline);
      expect(env.setRegionCalls, isEmpty);
    });

    test('skips when there is no usable location', () async {
      final env = _Env()..location = null;
      final controller = env.build();

      final status = await controller.ensure();

      expect(status.outcome, DeviceCountryConfigOutcome.skippedNoLocation);
    });

    test('skips when country resolution fails', () async {
      final env = _Env()
        ..geoError = const NetworkException('E_SDK_GEO_COUNTRY_UNKNOWN', 'x');
      final controller = env.build();

      final status = await controller.ensure();

      expect(status.outcome, DeviceCountryConfigOutcome.skippedCountryUnknown);
      expect(env.setRegionCalls, isEmpty);
    });

    test('falls back to EU868 when the backend omits a region byte', () async {
      final env = _Env()
        ..reportedRegion = LoraRegionCode.us915.wireValue // device on US915
        ..deviceConfig = DeviceCountryConfig.fromJson(
          // Unmapped country / byte-less config -> EU fallback (not a skip).
          <String, dynamic>{'region': 'LORA24'},
        );
      final controller = env.build();

      final status = await controller.ensure();

      expect(status.outcome, DeviceCountryConfigOutcome.applied);
      expect(status.targetRegion, LoraRegionCode.eu868);
      expect(env.setRegionCalls, <int>[LoraRegionCode.eu868.wireValue]);
    });

    test('does not reboot when the live device region cannot be read',
        () async {
      final env = _Env()..runtimeThrows = true;
      final controller = env.build();

      final status = await controller.ensure();

      expect(status.outcome, DeviceCountryConfigOutcome.skippedDeviceOffline);
      expect(env.setRegionCalls, isEmpty);
      expect(env.rebootCalls, 0);
    });

    test(
        'marks firmware unsupported when the region is not adopted, and does '
        'not reboot again on the next run', () async {
      final env = _Env()..applyAdoptsRegion = false; // firmware ignores 0x20
      final controller = env.build();

      final first = await controller.ensure();
      expect(
          first.outcome, DeviceCountryConfigOutcome.skippedFirmwareUnsupported);
      expect(env.setRegionCalls, hasLength(1));
      expect(env.rebootCalls, 1);
      final record = await env.store.getRecord('hw-1');
      expect(record!.applied, isFalse);

      final second = await controller.ensure();
      expect(
        second.outcome,
        DeviceCountryConfigOutcome.skippedFirmwareUnsupported,
      );
      // No additional setRegion / reboot — the unsupported verdict is honored.
      expect(env.setRegionCalls, hasLength(1));
      expect(env.rebootCalls, 1);
    });

    test('guards against concurrent runs', () async {
      final env = _Env()..holdGate = Completer<void>();
      final controller = env.build();

      final first = controller.ensure(reason: 'first');
      // Second call observes the in-flight guard and returns immediately.
      final second = await controller.ensure(reason: 'second');
      expect(second.outcome, DeviceCountryConfigOutcome.idle);

      env.holdGate!.complete();
      final firstResult = await first;
      expect(firstResult.outcome, DeviceCountryConfigOutcome.applied);
      expect(env.setRegionCalls, hasLength(1));
    });

    test('emits each terminal status on the stream', () async {
      final env = _Env()..reportedRegion = LoraRegionCode.us915.wireValue;
      final controller = env.build();
      final emitted = <DeviceCountryConfigOutcome>[];
      final sub =
          controller.watchStatus().listen((s) => emitted.add(s.outcome));

      await controller.ensure();
      await Future<void>.delayed(Duration.zero);

      expect(emitted, contains(DeviceCountryConfigOutcome.skippedUpToDate));
      await sub.cancel();
    });

    test('emits applying BEFORE the terminal outcome on a real apply',
        () async {
      final env = _Env(); // device EU868(3), US -> US915(1): a real apply
      final controller = env.build();
      final emitted = <DeviceCountryConfigOutcome>[];
      final sub =
          controller.watchStatus().listen((s) => emitted.add(s.outcome));

      await controller.ensure();
      await Future<void>.delayed(Duration.zero);

      // The loading state must precede success so the host can show a modal.
      expect(
        emitted,
        containsAllInOrder(<DeviceCountryConfigOutcome>[
          DeviceCountryConfigOutcome.applying,
          DeviceCountryConfigOutcome.applied,
        ]),
      );
      await sub.cancel();
    });

    test('does NOT emit applying when the device is already up to date',
        () async {
      final env = _Env()..reportedRegion = LoraRegionCode.us915.wireValue;
      final controller = env.build();
      final emitted = <DeviceCountryConfigOutcome>[];
      final sub =
          controller.watchStatus().listen((s) => emitted.add(s.outcome));

      await controller.ensure();
      await Future<void>.delayed(Duration.zero);

      // A no-op skip stays transparent (no loading modal).
      expect(emitted, isNot(contains(DeviceCountryConfigOutcome.applying)));
      expect(emitted, contains(DeviceCountryConfigOutcome.skippedUpToDate));
      await sub.cancel();
    });
  });
}

DeviceStatus _connectedDevice() => const DeviceStatus(
      deviceId: 'ble-1',
      canonicalHardwareId: 'hw-1',
      nodeId: 7,
      paired: true,
      activated: true,
      connected: true,
    );

SdkResolvedLocation _validLocation() => SdkResolvedLocation(
      latitude: 40.0,
      longitude: -100.0,
      timestamp: DateTime.parse('2026-06-30T12:00:00Z'),
      source: SdkLocationSource.connectedDevice,
      isFresh: true,
      isValid: true,
      authoritativeForBackend: true,
    );

DeviceRuntimeStatus _runtime(int region) => DeviceRuntimeStatus(
      region: region,
      modemPreset: 0,
      meshSpreadingFactor: 9,
      isProvisioned: true,
      usePreset: true,
      txEnabled: true,
      inetOk: false,
      positionConfirmed: false,
      nodeId: 7,
      batteryPercent: 80,
      telIntervalSeconds: 120,
    );

class _Env {
  int reportedRegion = LoraRegionCode.eu868.wireValue;
  bool runtimeThrows = false;
  bool applyAdoptsRegion = true;
  DeviceStatus? device = _connectedDevice();
  String? safetyReason;
  SdkResolvedLocation? location = _validLocation();
  Object? geoError;
  String geoCountryIso = 'US';
  DeviceCountryConfig deviceConfig = DeviceCountryConfig.fromJson(
    <String, dynamic>{
      'region': 'US915',
      'lora_region_code': 1,
      'country': 'US',
    },
  );
  Object? deviceConfigError;
  Completer<void>? holdGate;

  final List<int> setRegionCalls = <int>[];
  int rebootCalls = 0;
  DateTime now = DateTime.parse('2026-06-30T12:00:00Z');
  final DeviceConfigStore store =
      DeviceConfigStore(localStore: SharedPrefsSdkStore());

  DeviceCountryConfigController build() {
    return DeviceCountryConfigController(
      geoCountrySource: _FakeGeo(this),
      deviceConfigSource: _FakeDeviceConfig(this),
      store: store,
      locationProvider: () async => location,
      runtimeStatusProvider: () async {
        if (runtimeThrows) {
          throw const DeviceException(
            'E_DEVICE_COMMAND_NOT_READY',
            'E_DEVICE_COMMAND_NOT_READY',
          );
        }
        return _runtime(reportedRegion);
      },
      setRegionCommand: (code) async {
        setRegionCalls.add(code);
        if (applyAdoptsRegion) {
          reportedRegion = code;
        }
      },
      rebootCommand: () async {
        rebootCalls += 1;
      },
      deviceStatusProvider: () => device,
      safetyHoldReason: () async {
        if (holdGate != null) {
          await holdGate!.future;
        }
        return safetyReason;
      },
      clock: () => now,
      delay: (duration) async {
        now = now.add(duration);
      },
      verifyTimeout: const Duration(seconds: 30),
      verifyPollInterval: const Duration(seconds: 3),
    );
  }
}

class _FakeGeo implements SdkGeoCountryRemoteDataSource {
  _FakeGeo(this.env);

  final _Env env;

  @override
  Future<ResolvedCountry> resolveCountry({
    required double latitude,
    required double longitude,
  }) async {
    final error = env.geoError;
    if (error != null) {
      throw error;
    }
    return ResolvedCountry(
      countryIso: env.geoCountryIso,
      latitude: latitude,
      longitude: longitude,
    );
  }
}

class _FakeDeviceConfig implements SdkDeviceConfigRemoteDataSource {
  _FakeDeviceConfig(this.env);

  final _Env env;

  @override
  Future<DeviceCountryConfig> fetchByCountry({String? countryIso}) async {
    final error = env.deviceConfigError;
    if (error != null) {
      throw error;
    }
    return env.deviceConfig;
  }
}
