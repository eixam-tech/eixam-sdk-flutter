import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'shared_prefs_sdk_store.dart';

/// Store-internal record of the last region apply *attempt* for a device.
///
/// [applied] distinguishes a verified apply (`true`) from an attempt the device
/// never adopted (`false`) — the latter lets the SDK avoid rebooting a device
/// whose firmware does not yet implement the region command on every launch.
class DeviceConfigRecord {
  const DeviceConfigRecord({
    required this.countryIso,
    required this.regionWire,
    required this.applied,
    this.deviceConfig,
    this.at,
  });

  factory DeviceConfigRecord.fromJson(Map<String, dynamic> json) {
    final iso = json['countryIso'];
    final wire = json['regionWire'];
    final spec = json['deviceConfig'];
    final applied = json['applied'];
    final atRaw = json['at'];
    return DeviceConfigRecord(
      countryIso: iso is String ? iso : '',
      regionWire: wire is num ? wire.toInt() : 0,
      // Default false: an unknown/missing flag must NOT be read as "applied"
      // (that would bypass the firmware-unsupported cooldown and re-reboot).
      applied: applied is bool ? applied : false,
      deviceConfig: spec is String ? spec : null,
      at: atRaw is String ? DateTime.tryParse(atRaw) : null,
    );
  }

  final String countryIso;
  final int regionWire;
  final bool applied;
  final String? deviceConfig;
  final DateTime? at;

  LoraRegionCode get region => LoraRegionCode.fromWireValue(regionWire);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'countryIso': countryIso,
        'regionWire': regionWire,
        'applied': applied,
        if (deviceConfig != null) 'deviceConfig': deviceConfig,
        if (at != null) 'at': at!.toIso8601String(),
      };
}

/// Persists the last per-country radio config attempt for each device, keyed by
/// a stable device id, so the SDK can skip re-applying an unchanged region and
/// avoid rebooting devices whose firmware has not adopted the region command.
/// Multi-device safe: records live under a single JSON map keyed by device.
class DeviceConfigStore {
  DeviceConfigStore({SharedPrefsSdkStore? localStore})
      : _localStore = localStore ?? SharedPrefsSdkStore();

  final SharedPrefsSdkStore _localStore;

  /// Records a verified region apply.
  Future<void> saveApplied({
    required String deviceKey,
    required String countryIso,
    required int regionWire,
    String? deviceConfig,
    DateTime? at,
  }) {
    return _save(
      deviceKey: deviceKey,
      countryIso: countryIso,
      regionWire: regionWire,
      applied: true,
      deviceConfig: deviceConfig,
      at: at,
    );
  }

  /// Records an attempt the device never adopted (e.g. firmware without the
  /// region command), so the SDK does not reboot it again every launch.
  Future<void> saveUnsupportedAttempt({
    required String deviceKey,
    required String countryIso,
    required int regionWire,
    String? deviceConfig,
    DateTime? at,
  }) {
    return _save(
      deviceKey: deviceKey,
      countryIso: countryIso,
      regionWire: regionWire,
      applied: false,
      deviceConfig: deviceConfig,
      at: at,
    );
  }

  Future<DeviceConfigRecord?> getRecord(String deviceKey) async {
    final map = await _readMap();
    final entry = map[deviceKey];
    if (entry is Map) {
      return DeviceConfigRecord.fromJson(Map<String, dynamic>.from(entry));
    }
    return null;
  }

  Future<void> clear(String deviceKey) async {
    final map = await _readMap();
    if (map.remove(deviceKey) != null) {
      await _localStore.saveJson(
        SharedPrefsSdkStore.deviceCountryConfigKey,
        map,
      );
    }
  }

  Future<void> _save({
    required String deviceKey,
    required String countryIso,
    required int regionWire,
    required bool applied,
    String? deviceConfig,
    DateTime? at,
  }) async {
    final map = await _readMap();
    map[deviceKey] = DeviceConfigRecord(
      countryIso: countryIso,
      regionWire: regionWire,
      applied: applied,
      deviceConfig: deviceConfig,
      at: at ?? DateTime.now(),
    ).toJson();
    await _localStore.saveJson(SharedPrefsSdkStore.deviceCountryConfigKey, map);
  }

  Future<Map<String, dynamic>> _readMap() async {
    final raw =
        await _localStore.readJson(SharedPrefsSdkStore.deviceCountryConfigKey);
    if (raw == null) {
      return <String, dynamic>{};
    }
    return Map<String, dynamic>.from(raw);
  }
}
