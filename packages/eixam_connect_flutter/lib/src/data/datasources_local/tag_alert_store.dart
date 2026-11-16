import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'shared_prefs_sdk_store.dart';

/// Checked raw IO; serialized writes are reconciled by the controller.
abstract interface class TagAlertStore {
  Object get writerNamespace;
  Future<String?> read();
  Future<bool> write(String value);
  Future<bool> remove();
}

final class SharedPrefsTagAlertStore implements TagAlertStore {
  SharedPrefsTagAlertStore(this.localStore);

  final SharedPrefsSdkStore localStore;

  @override
  Object get writerNamespace => localStore.storageNamespace;
  @override
  Future<String?> read() =>
      localStore.readFreshString(SharedPrefsSdkStore.tagAlertsKey);
  @override
  Future<bool> write(String value) =>
      localStore.writeStringChecked(SharedPrefsSdkStore.tagAlertsKey, value);
  @override
  Future<bool> remove() =>
      localStore.removeChecked(SharedPrefsSdkStore.tagAlertsKey);
}

/// Versioned envelope: one blob with every device's settings, owned by one
/// identity scope.
final class TagAlertRecord {
  const TagAlertRecord({
    required this.ownerScope,
    required this.devices,
    this.cycles = const <String, TagBatteryCycle>{},
  });

  /// Throws [FormatException] for anything malformed, unsupported or newer.
  factory TagAlertRecord.decode(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map<String, Object?> ||
        json['v'] is! int ||
        json['v'] != TagAlertSettings.schemaVersion ||
        json['ownerScope'] is! String ||
        (json['ownerScope'] as String).isEmpty ||
        json['devices'] is! Map<String, Object?>) {
      throw const FormatException('Unsupported TAG alert store envelope.');
    }
    final devices = <String, TagAlertSettings>{};
    for (final entry in (json['devices'] as Map<String, Object?>).entries) {
      final settings = TagAlertSettings.fromJson(entry.value);
      if (settings.deviceId != entry.key) {
        throw const FormatException('TAG alert settings key mismatch.');
      }
      devices[entry.key] = settings;
    }
    final cycles = <String, TagBatteryCycle>{};
    final rawCycles = json['cycles'];
    if (rawCycles != null) {
      if (rawCycles is! Map<String, Object?>) {
        throw const FormatException('Unsupported TAG battery cycles.');
      }
      for (final entry in rawCycles.entries) {
        cycles[entry.key] = TagBatteryCycle.fromJson(entry.value);
      }
    }
    return TagAlertRecord(
      ownerScope: json['ownerScope'] as String,
      devices: Map<String, TagAlertSettings>.unmodifiable(devices),
      cycles: Map<String, TagBatteryCycle>.unmodifiable(cycles),
    );
  }

  final String ownerScope;
  final Map<String, TagAlertSettings> devices;

  /// Per-device low-battery cycle (which thresholds already alerted).
  final Map<String, TagBatteryCycle> cycles;

  String encode() => jsonEncode(<String, Object?>{
    'v': TagAlertSettings.schemaVersion,
    'ownerScope': ownerScope,
    'devices': <String, Object?>{
      for (final entry in devices.entries) entry.key: entry.value.toJson(),
    },
    if (cycles.isNotEmpty)
      'cycles': <String, Object?>{
        for (final entry in cycles.entries) entry.key: entry.value.toJson(),
      },
  });
}
