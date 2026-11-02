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

/// Detects when the connected BLE device differs from the backend config for
/// the current country, then applies that pending change only after the host
/// has obtained explicit user confirmation.
///
/// Detection ([check]) never writes or reboots. Application ([applyPending])
/// re-checks identity, safety and live device state immediately before driving
/// the setRegion -> reboot -> verify loop. Both entry points are guarded,
/// best-effort and never throw.
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
  _PendingDeviceCountryConfig? _pending;
  Completer<void>? _operationDone;

  Stream<DeviceCountryConfigStatus> watchStatus() => _statusController.stream;

  DeviceCountryConfigStatus get lastStatus => _lastStatus;

  Future<void> dispose() async {
    await _statusController.close();
  }

  /// Detects a mismatch without changing the device.
  Future<DeviceCountryConfigStatus> check({
    String reason = 'manual',
    String? countryIsoOverride,
  }) async {
    await _acquireOperation();
    try {
      return await _check(reason, countryIsoOverride: countryIsoOverride);
    } catch (error) {
      _pending = null;
      return _emit(
        DeviceCountryConfigOutcome.failed,
        detail: 'Unexpected check error ($reason): $error',
      );
    } finally {
      _finishOperation();
    }
  }

  /// Applies the most recently detected mismatch after host confirmation.
  Future<DeviceCountryConfigStatus> applyPending({
    String reason = 'user_confirmed',
  }) async {
    // A lifecycle re-check may overlap the user's tap. Serialize the apply
    // behind it so confirmation uses the freshly validated plan. If that check
    // invalidates the plan, return its detection status rather than inventing a
    // misleading apply failure for a modal that is no longer actionable.
    final overlappedOperation = _operationDone != null;
    await _acquireOperation();
    try {
      if (overlappedOperation &&
          _pending == null &&
          !_lastStatus.requiresConfirmation) {
        return _lastStatus;
      }
      return await _applyPending(reason);
    } catch (error) {
      _pending = null;
      return _emit(
        DeviceCountryConfigOutcome.failed,
        applyAttempted: true,
        detail: 'Unexpected apply error ($reason): $error',
      );
    } finally {
      _finishOperation();
    }
  }

  /// Deprecated compatibility alias. It deliberately remains detection-only;
  /// no public SDK method may apply a region without explicit confirmation.
  @Deprecated('Use check, then applyPending after explicit user confirmation.')
  Future<DeviceCountryConfigStatus> ensure({String reason = 'manual'}) =>
      check(reason: reason);

  Future<DeviceCountryConfigStatus> _check(
    String reason, {
    String? countryIsoOverride,
  }) async {
    // 1. A command-capable device must be connected.
    final deviceStatus = deviceStatusProvider();
    if (deviceStatus == null || !deviceStatus.connected) {
      return _emitCheckTerminal(
        DeviceCountryConfigOutcome.skippedDeviceOffline,
        detail: 'No connected device (reason=$reason)',
      );
    }
    final deviceKey = _deviceKeyFor(deviceStatus);

    // 2. Safety gate FIRST: never reboot during an active safety flow.
    final hold = await safetyHoldReason();
    if (hold != null) {
      return _emitCheckTerminal(
        DeviceCountryConfigOutcome.skippedSafetyActive,
        detail: hold,
      );
    }

    // 3-4. Resolve the ISO country. Production uses an AUTHORITATIVE fix
    // (connected-device / phone). A host development tool may supply a country
    // override; this only bypasses geo resolution and still exercises backend
    // config lookup plus the real device compare/apply/verify flow.
    final String countryIso;
    final override = countryIsoOverride?.trim().toUpperCase();
    if (override != null && override.isNotEmpty) {
      countryIso = override;
    } else {
    final location = await locationProvider();
    if (location == null ||
        !location.isValid ||
        !location.authoritativeForBackend) {
        return _emitCheckTerminal(DeviceCountryConfigOutcome.skippedNoLocation);
    }
    try {
      final resolved = await geoCountrySource.resolveCountry(
        latitude: location.latitude,
        longitude: location.longitude,
      );
      countryIso = resolved.countryIso;
    } catch (error) {
        return _emitCheckTerminal(
        DeviceCountryConfigOutcome.skippedCountryUnknown,
        detail: 'Country resolution failed: $error',
      );
    }
    }

    // 5. Fetch the per-country config and map it to a target region.
    final DeviceCountryConfig? config;
    try {
      config = await deviceConfigSource.fetchByCountry(countryIso: countryIso);
    } catch (error) {
      return _emitCheckTerminal(
        DeviceCountryConfigOutcome.skippedCountryUnknown,
        countryIso: countryIso,
        detail: 'Device config fetch failed: $error',
      );
    }
    // No backend config for this country and no default (404): skip. Applying
    // the EU868 fallback here would reboot a device physically outside the EU
    // onto a region illegal for where it actually is.
    if (config == null) {
      return _emitCheckTerminal(
        DeviceCountryConfigOutcome.skippedCountryUnknown,
        countryIso: countryIso,
        detail: 'No device config for country $countryIso (backend 404)',
      );
    }
    // The region byte is taken verbatim from the backend config; when a config
    // EXISTS but omits/zeroes the byte it falls back to EU868 (see
    // DeviceCountryConfig.regionByte) — the backend explicitly chose to answer
    // for this country, so there is always a legal region to apply.
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
        return _emitCheckTerminal(
          DeviceCountryConfigOutcome.skippedUpToDate,
          countryIso: countryIso,
          targetRegion: targetLabel,
          deviceReportedRegion: deviceRegion,
          deviceConfig: config.deviceConfig,
        );
      }
    } catch (error) {
      return _emitCheckTerminal(
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
      return _emitCheckTerminal(
        DeviceCountryConfigOutcome.skippedFirmwareUnsupported,
        countryIso: countryIso,
        targetRegion: targetLabel,
        deviceReportedRegion: deviceRegion,
        deviceConfig: config.deviceConfig,
        detail:
            'Device did not adopt a region previously (firmware likely '
            'lacks the region command)',
      );
    }

    // 7. Publish a pending change. The host now owns explicit confirmation;
    // detection stops here without sending any BLE command or rebooting.
    _pending = _PendingDeviceCountryConfig(
      deviceKey: deviceKey,
      countryIso: countryIso,
      targetWire: target,
      targetRegion: targetLabel,
      deviceReportedRegion: deviceRegion,
      deviceConfig: config.deviceConfig,
    );
      return _emit(
      DeviceCountryConfigOutcome.updateAvailable,
        countryIso: countryIso,
        targetRegion: targetLabel,
        deviceReportedRegion: deviceRegion,
        deviceConfig: config.deviceConfig,
      );
    }

  Future<DeviceCountryConfigStatus> _applyPending(String reason) async {
    final pending = _pending;
    if (pending == null) {
      return _emit(
        DeviceCountryConfigOutcome.failed,
        applyAttempted: true,
        detail: 'No pending device region update (reason=$reason)',
      );
    }

    final deviceStatus = deviceStatusProvider();
    if (deviceStatus == null || !deviceStatus.connected) {
      return _emit(
        DeviceCountryConfigOutcome.skippedDeviceOffline,
        applyAttempted: true,
        canRetry: true,
        countryIso: pending.countryIso,
        targetRegion: pending.targetRegion,
        deviceReportedRegion: pending.deviceReportedRegion,
        deviceConfig: pending.deviceConfig,
        detail: 'Pending device is temporarily offline (reason=$reason)',
      );
    }
    if (_deviceKeyFor(deviceStatus) != pending.deviceKey) {
      _pending = null;
      return _emit(
        DeviceCountryConfigOutcome.skippedDeviceOffline,
        applyAttempted: true,
        countryIso: pending.countryIso,
        targetRegion: pending.targetRegion,
        deviceReportedRegion: pending.deviceReportedRegion,
        deviceConfig: pending.deviceConfig,
        detail: 'A different device is connected (reason=$reason)',
      );
    }

    // User confirmation may arrive well after detection. Re-check both safety
    // and the live region before doing anything that can reboot the device.
    final hold = await safetyHoldReason();
    if (hold != null) {
      return _emit(
        DeviceCountryConfigOutcome.skippedSafetyActive,
        applyAttempted: true,
        canRetry: true,
        countryIso: pending.countryIso,
        targetRegion: pending.targetRegion,
        deviceReportedRegion: pending.deviceReportedRegion,
        deviceConfig: pending.deviceConfig,
        detail: hold,
      );
    }

    LoraRegionCode liveRegion;
    try {
      final runtime = await runtimeStatusProvider();
      liveRegion = LoraRegionCode.fromWireValue(runtime.region);
      if (runtime.region == pending.targetWire) {
        _pending = null;
        await store.saveApplied(
          deviceKey: pending.deviceKey,
          countryIso: pending.countryIso,
          regionWire: pending.targetWire,
          deviceConfig: pending.deviceConfig,
          at: _clock(),
        );
        return _emit(
          DeviceCountryConfigOutcome.skippedUpToDate,
          applyAttempted: true,
          countryIso: pending.countryIso,
          targetRegion: pending.targetRegion,
          deviceReportedRegion: liveRegion,
          deviceConfig: pending.deviceConfig,
        );
      }
    } catch (error) {
      return _emit(
        DeviceCountryConfigOutcome.skippedDeviceOffline,
        applyAttempted: true,
        canRetry: true,
        countryIso: pending.countryIso,
        targetRegion: pending.targetRegion,
        deviceReportedRegion: pending.deviceReportedRegion,
        deviceConfig: pending.deviceConfig,
        detail: 'Could not re-read device region: $error',
      );
    }

    final holdBeforeWrite = await safetyHoldReason();
    if (holdBeforeWrite != null) {
      return _emit(
        DeviceCountryConfigOutcome.skippedSafetyActive,
        applyAttempted: true,
        canRetry: true,
        countryIso: pending.countryIso,
        targetRegion: pending.targetRegion,
        deviceReportedRegion: liveRegion,
        deviceConfig: pending.deviceConfig,
        detail: holdBeforeWrite,
      );
    }

    // Signal progress only after all late gates pass and the write is about to
    // start. The modal also switches to loading immediately on confirmation.
    _emit(
      DeviceCountryConfigOutcome.applying,
      applyAttempted: true,
      countryIso: pending.countryIso,
      targetRegion: pending.targetRegion,
      deviceReportedRegion: liveRegion,
      deviceConfig: pending.deviceConfig,
    );
    // From this point a BLE write may have reached the device even if the
    // transport later reports an error. Consume the plan before dispatch and
    // require a fresh detection after any write-side failure.
    _pending = null;
    try {
      await setRegionCommand(pending.targetWire);
    } catch (error) {
      return _emit(
        DeviceCountryConfigOutcome.failed,
        applyAttempted: true,
        countryIso: pending.countryIso,
        targetRegion: pending.targetRegion,
        deviceReportedRegion: liveRegion,
        deviceConfig: pending.deviceConfig,
        detail: 'setRegion failed: $error',
      );
    }
    try {
      await rebootCommand();
    } catch (_) {
      // Some firmware auto-reboots after provisioning; tolerate reboot errors
      // and fall through to verification.
    }

    final adopted = await _waitForRegion(pending.targetWire);
    if (adopted) {
      await store.saveApplied(
        deviceKey: pending.deviceKey,
        countryIso: pending.countryIso,
        regionWire: pending.targetWire,
        deviceConfig: pending.deviceConfig,
        at: _clock(),
      );
      return _emit(
        DeviceCountryConfigOutcome.applied,
        applyAttempted: true,
        countryIso: pending.countryIso,
        targetRegion: pending.targetRegion,
        deviceReportedRegion: pending.targetRegion,
        deviceConfig: pending.deviceConfig,
      );
    }

    await store.saveUnsupportedAttempt(
      deviceKey: pending.deviceKey,
      countryIso: pending.countryIso,
      regionWire: pending.targetWire,
      deviceConfig: pending.deviceConfig,
      at: _clock(),
    );
    return _emit(
      DeviceCountryConfigOutcome.skippedFirmwareUnsupported,
      applyAttempted: true,
      countryIso: pending.countryIso,
      targetRegion: pending.targetRegion,
      deviceReportedRegion: liveRegion,
      deviceConfig: pending.deviceConfig,
      detail: 'Device did not adopt region ${pending.targetWire} after reboot',
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
    bool applyAttempted = false,
    bool canRetry = false,
    String? countryIso,
    LoraRegionCode? targetRegion,
    LoraRegionCode? deviceReportedRegion,
    String? deviceConfig,
    String? detail,
  }) {
    final status = DeviceCountryConfigStatus(
      outcome: outcome,
      updatedAt: _clock(),
      applyAttempted: applyAttempted,
      canRetry: canRetry,
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

  DeviceCountryConfigStatus _emitCheckTerminal(
    DeviceCountryConfigOutcome outcome, {
    String? countryIso,
    LoraRegionCode? targetRegion,
    LoraRegionCode? deviceReportedRegion,
    String? deviceConfig,
    String? detail,
  }) {
    // A completed detection replaces or invalidates any older confirmation.
    // The UI uses applyAttempted=false to close a now-stale prompt quietly.
    _pending = null;
    return _emit(
      outcome,
      countryIso: countryIso,
      targetRegion: targetRegion,
      deviceReportedRegion: deviceReportedRegion,
      deviceConfig: deviceConfig,
      detail: detail,
    );
  }

  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);

  Future<void> _acquireOperation() async {
    while (true) {
      final running = _operationDone;
      if (running == null) {
        _operationDone = Completer<void>();
        return;
      }
      await running.future;
    }
  }

  void _finishOperation() {
    final done = _operationDone;
    _operationDone = null;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
  }
}

final class _PendingDeviceCountryConfig {
  const _PendingDeviceCountryConfig({
    required this.deviceKey,
    required this.countryIso,
    required this.targetWire,
    required this.targetRegion,
    required this.deviceReportedRegion,
    required this.deviceConfig,
  });

  final String deviceKey;
  final String countryIso;
  final int targetWire;
  final LoraRegionCode targetRegion;
  final LoraRegionCode deviceReportedRegion;
  final String? deviceConfig;
}
