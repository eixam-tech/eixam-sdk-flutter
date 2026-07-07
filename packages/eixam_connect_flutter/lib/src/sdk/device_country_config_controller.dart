import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/device_config_store.dart';
import '../data/datasources_remote/sdk_device_config_remote_data_source.dart';
import '../data/datasources_remote/sdk_geo_country_remote_data_source.dart';

typedef ResolvedLocationProvider = Future<SdkResolvedLocation?> Function();
typedef DeviceRuntimeStatusProvider = Future<DeviceRuntimeStatus> Function();
typedef SetRegionCommand = Future<void> Function(int regionCode);
typedef DeviceRebootCommand = Future<void> Function();
typedef ConnectedDeviceStatusProvider = DeviceStatus? Function();

/// Returns a non-null reason when an apply must be deferred because a safety
/// flow (SOS / PreSOS / Death-Man / protection runtime) is active; null when
/// it is safe to reboot the device.
typedef SafetyHoldReasonProvider = Future<String?> Function();

/// Keeps the connected BLE device configured with the per-country radio config
/// (LoRa region) legal for the country it is physically in.
///
/// Modeled on `FirmwareUpdateCoordinator`: a single guarded entry point
/// ([ensure]) runs ordered skip gates before ever writing a region or
/// rebooting, drives a setRegion -> reboot -> verify loop, and never throws.
/// Safety is the first hard gate — a region change reboots the device, so it is
/// deferred whenever a safety flow is active.
class DeviceCountryConfigController {
  DeviceCountryConfigController({
    required this.geoCountrySource,
    required this.deviceConfigSource,
    required this.store,
    required this.locationProvider,
    required this.runtimeStatusProvider,
    required this.setRegionCommand,
    required this.rebootCommand,
    required this.deviceStatusProvider,
    required this.safetyHoldReason,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    Duration verifyTimeout = const Duration(seconds: 120),
    Duration verifyPollInterval = const Duration(seconds: 3),
    Duration unsupportedCooldown = const Duration(hours: 24),
  })  : _clock = clock ?? DateTime.now,
        _delay = delay ?? _defaultDelay,
        _verifyTimeout = verifyTimeout,
        _verifyPollInterval = verifyPollInterval,
        _unsupportedCooldown = unsupportedCooldown;

  final SdkGeoCountryRemoteDataSource geoCountrySource;
  final SdkDeviceConfigRemoteDataSource deviceConfigSource;
  final DeviceConfigStore store;
  final ResolvedLocationProvider locationProvider;
  final DeviceRuntimeStatusProvider runtimeStatusProvider;
  final SetRegionCommand setRegionCommand;
  final DeviceRebootCommand rebootCommand;
  final ConnectedDeviceStatusProvider deviceStatusProvider;
  final SafetyHoldReasonProvider safetyHoldReason;

  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final Duration _verifyTimeout;
  final Duration _verifyPollInterval;
  final Duration _unsupportedCooldown;

  final StreamController<DeviceCountryConfigStatus> _statusController =
      StreamController<DeviceCountryConfigStatus>.broadcast();
  DeviceCountryConfigStatus _lastStatus = DeviceCountryConfigStatus.idle();
  bool _inFlight = false;

  Stream<DeviceCountryConfigStatus> watchStatus() => _statusController.stream;

  DeviceCountryConfigStatus get lastStatus => _lastStatus;

  Future<void> dispose() async {
    await _statusController.close();
  }

  /// Single entry point. Best-effort and idempotent: never throws, returns the
  /// terminal [DeviceCountryConfigStatus], and is guarded against concurrent
  /// runs (overlapping calls return the current status without re-running).
  Future<DeviceCountryConfigStatus> ensure({String reason = 'manual'}) async {
    if (_inFlight) {
      return _lastStatus;
    }
    _inFlight = true;
    try {
      return await _run(reason);
    } catch (error) {
      return _emit(
        DeviceCountryConfigOutcome.failed,
        detail: 'Unexpected error ($reason): $error',
      );
    } finally {
      _inFlight = false;
    }
  }

  Future<DeviceCountryConfigStatus> _run(String reason) async {
    // 1. A command-capable device must be connected.
    final deviceStatus = deviceStatusProvider();
    if (deviceStatus == null || !deviceStatus.connected) {
      return _emit(
        DeviceCountryConfigOutcome.skippedDeviceOffline,
        detail: 'No connected device (reason=$reason)',
      );
    }
    final deviceKey = _deviceKeyFor(deviceStatus);

    // 2. Safety gate FIRST: never reboot during an active safety flow.
    final hold = await safetyHoldReason();
    if (hold != null) {
      return _emit(DeviceCountryConfigOutcome.skippedSafetyActive,
          detail: hold);
    }

    // 3. Resolve the device's physical location. Require an AUTHORITATIVE fix
    // (connected-device / phone) — a cached / backend-snapshot / relay
    // coordinate could resolve the wrong country and reboot the device onto a
    // region illegal for where it actually is.
    final location = await locationProvider();
    if (location == null ||
        !location.isValid ||
        !location.authoritativeForBackend) {
      return _emit(DeviceCountryConfigOutcome.skippedNoLocation);
    }

    // 4. Resolve the ISO country for that location (backend geo endpoint).
    final String countryIso;
    try {
      final resolved = await geoCountrySource.resolveCountry(
        latitude: location.latitude,
        longitude: location.longitude,
      );
      countryIso = resolved.countryIso;
    } catch (error) {
      return _emit(
        DeviceCountryConfigOutcome.skippedCountryUnknown,
        detail: 'Country resolution failed: $error',
      );
    }

    // 5. Fetch the per-country config and map it to a target region.
    final DeviceCountryConfig config;
    try {
      config = await deviceConfigSource.fetchByCountry(countryIso: countryIso);
    } catch (error) {
      return _emit(
        DeviceCountryConfigOutcome.skippedCountryUnknown,
        countryIso: countryIso,
        detail: 'Device config fetch failed: $error',
      );
    }
    // The region byte is taken verbatim from the backend config; when the
    // backend is unmapped it already falls back to EU868 (see
    // DeviceCountryConfig.regionByte), so there is always a legal region to
    // apply — the SDK never skips a device for a "missing" region.
    final int target = config.regionByte;
    final LoraRegionCode targetLabel = LoraRegionCode.fromWireValue(target);

    // 6. Idempotency: only reboot when the live device region differs. Without
    // a confirmed live region we must not reboot a safety device.
    final LoraRegionCode deviceRegion;
    try {
      final runtime = await runtimeStatusProvider();
      deviceRegion = LoraRegionCode.fromWireValue(runtime.region);
      if (runtime.region == target) {
        await store.saveApplied(
          deviceKey: deviceKey,
          countryIso: countryIso,
          regionWire: target,
          deviceConfig: config.deviceConfig,
          at: _clock(),
        );
        return _emit(
          DeviceCountryConfigOutcome.skippedUpToDate,
          countryIso: countryIso,
          targetRegion: targetLabel,
          deviceReportedRegion: deviceRegion,
          deviceConfig: config.deviceConfig,
        );
      }
    } catch (error) {
      return _emit(
        DeviceCountryConfigOutcome.skippedDeviceOffline,
        countryIso: countryIso,
        targetRegion: targetLabel,
        deviceConfig: config.deviceConfig,
        detail: 'Could not read device region: $error',
      );
    }

    // 6b. Don't reboot a device whose firmware already declined this exact
    // region recently (e.g. firmware without the region command). The verdict
    // is persisted so a cold restart does not reboot the device again.
    final record = await store.getRecord(deviceKey);
    if (record != null &&
        !record.applied &&
        record.at != null &&
        _clock().difference(record.at!) < _unsupportedCooldown) {
      // Device-wide verdict: a recent failed adopt means the firmware likely
      // lacks the region command, so suppress re-attempts for ANY target until
      // the cooldown elapses — a border crossing (different target) must not
      // re-trigger reboots on unsupported firmware.
      return _emit(
        DeviceCountryConfigOutcome.skippedFirmwareUnsupported,
        countryIso: countryIso,
        targetRegion: targetLabel,
        deviceReportedRegion: deviceRegion,
        deviceConfig: config.deviceConfig,
        detail: 'Device did not adopt a region previously (firmware likely '
            'lacks the region command)',
      );
    }

    // 7. Re-check safety immediately before the reboot-causing write: an
    // SOS / PreSOS / Death-Man / protection flow may have started during the
    // awaits above (location, geo, config, status), and a reboot must never
    // interrupt an active safety flow.
    final holdBeforeApply = await safetyHoldReason();
    if (holdBeforeApply != null) {
      return _emit(
        DeviceCountryConfigOutcome.skippedSafetyActive,
        countryIso: countryIso,
        targetRegion: targetLabel,
        deviceReportedRegion: deviceRegion,
        deviceConfig: config.deviceConfig,
        detail: holdBeforeApply,
      );
    }

    // 8. Apply: signal the in-progress state (drives the host's loading modal)
    // — emitted only here, once we're committed to a real write+reboot — then
    // write the region, reboot, and verify the device adopted it.
    _emit(
      DeviceCountryConfigOutcome.applying,
      countryIso: countryIso,
      targetRegion: targetLabel,
      deviceReportedRegion: deviceRegion,
      deviceConfig: config.deviceConfig,
    );
    try {
      await setRegionCommand(target);
    } catch (error) {
      return _emit(
        DeviceCountryConfigOutcome.failed,
        countryIso: countryIso,
        targetRegion: targetLabel,
        deviceReportedRegion: deviceRegion,
        deviceConfig: config.deviceConfig,
        detail: 'setRegion failed: $error',
      );
    }
    try {
      await rebootCommand();
    } catch (_) {
      // Some firmware auto-reboots after provisioning; tolerate reboot errors
      // and fall through to verification.
    }

    final adopted = await _waitForRegion(target);
    if (adopted) {
      await store.saveApplied(
        deviceKey: deviceKey,
        countryIso: countryIso,
        regionWire: target,
        deviceConfig: config.deviceConfig,
        at: _clock(),
      );
      return _emit(
        DeviceCountryConfigOutcome.applied,
        countryIso: countryIso,
        targetRegion: targetLabel,
        deviceReportedRegion: targetLabel,
        deviceConfig: config.deviceConfig,
      );
    }

    await store.saveUnsupportedAttempt(
      deviceKey: deviceKey,
      countryIso: countryIso,
      regionWire: target,
      deviceConfig: config.deviceConfig,
      at: _clock(),
    );
    return _emit(
      DeviceCountryConfigOutcome.skippedFirmwareUnsupported,
      countryIso: countryIso,
      targetRegion: targetLabel,
      deviceReportedRegion: deviceRegion,
      deviceConfig: config.deviceConfig,
      detail: 'Device did not adopt region $target after reboot',
    );
  }

  /// Polls device status until it reports [target] or the deadline elapses.
  /// Only reads status — reconnection is owned by the auto-reconnect coordinator.
  Future<bool> _waitForRegion(int target) async {
    final deadline = _clock().add(_verifyTimeout);
    while (true) {
      try {
        final status = await runtimeStatusProvider();
        if (status.region == target) {
          return true;
        }
      } catch (_) {
        // Device is rebooting / reconnecting; keep polling until the deadline.
      }
      if (!_clock().isBefore(deadline)) {
        return false;
      }
      await _delay(_verifyPollInterval);
    }
  }

  String _deviceKeyFor(DeviceStatus status) => deviceKeyFor(status);

  /// Stable per-device key (canonical hardware id, else node id, else device
  /// id). Shared so callers (e.g. unpair cleanup) target the same record.
  static String deviceKeyFor(DeviceStatus status) {
    final hardware = status.canonicalHardwareId?.trim();
    if (hardware != null && hardware.isNotEmpty) {
      return hardware;
    }
    final node = status.nodeId;
    if (node != null) {
      return 'node:$node';
    }
    return status.deviceId;
  }

  DeviceCountryConfigStatus _emit(
    DeviceCountryConfigOutcome outcome, {
    String? countryIso,
    LoraRegionCode? targetRegion,
    LoraRegionCode? deviceReportedRegion,
    String? deviceConfig,
    String? detail,
  }) {
    final status = DeviceCountryConfigStatus(
      outcome: outcome,
      updatedAt: _clock(),
      countryIso: countryIso,
      targetRegion: targetRegion,
      deviceReportedRegion: deviceReportedRegion,
      deviceConfig: deviceConfig,
      detail: detail,
    );
    _lastStatus = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
    return status;
  }

  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);
}
