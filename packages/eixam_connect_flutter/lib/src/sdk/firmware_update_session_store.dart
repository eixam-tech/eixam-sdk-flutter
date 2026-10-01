import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/shared_prefs_sdk_store.dart';

abstract interface class FirmwareUpdateSessionStore {
  Future<FirmwareUpdateSession?> load();
  Future<void> save(FirmwareUpdateSession session);
  Future<void> clear();
}

final class SharedPrefsFirmwareUpdateSessionStore
    implements FirmwareUpdateSessionStore {
  SharedPrefsFirmwareUpdateSessionStore({SharedPrefsSdkStore? localStore})
    : _localStore = localStore ?? SharedPrefsSdkStore();

  final SharedPrefsSdkStore _localStore;

  @override
  Future<FirmwareUpdateSession?> load() async {
    final json = await _localStore.readJson(
      SharedPrefsSdkStore.firmwareUpdateSessionKey,
    );
    if (json == null) {
      await clear();
      return null;
    }
    try {
      if (json['schemaVersion'] != FirmwareUpdateSession.currentSchemaVersion) {
        await clear();
        return null;
      }
      final session = _decode(json);
      if (session.isCompleted) {
        await clear();
        return null;
      }
      return session;
    } catch (_) {
      await clear();
      return null;
    }
  }

  @override
  Future<void> save(FirmwareUpdateSession session) {
    return _localStore.saveJson(
      SharedPrefsSdkStore.firmwareUpdateSessionKey,
      <String, dynamic>{
        'schemaVersion': session.schemaVersion,
        'sessionId': session.sessionId,
        'deviceId': session.deviceId,
        'hardwareId': session.hardwareId,
        'releaseId': session.releaseId,
        'fromVersion': session.fromVersion,
        'targetVersion': session.targetVersion,
        'state': session.state.name,
        'startedAt': session.startedAt.toUtc().toIso8601String(),
        'updatedAt': (session.updatedAt ?? session.startedAt)
            .toUtc()
            .toIso8601String(),
        'completedAt': session.completedAt?.toUtc().toIso8601String(),
        'failureCode': session.failureCode,
        'failureMessage': session.failureMessage,
        'nativeTransferEngaged': session.nativeTransferEngaged,
        'requiresRecovery': session.requiresRecovery,
        'nextAction': session.nextAction.name,
        'reconciliationOutcome': session.reconciliationOutcome?.name,
      },
    );
  }

  @override
  Future<void> clear() {
    return _localStore.remove(SharedPrefsSdkStore.firmwareUpdateSessionKey);
  }

  FirmwareUpdateSession _decode(Map<String, dynamic> json) {
    return FirmwareUpdateSession(
      sessionId: _string(json, 'sessionId'),
      deviceId: _string(json, 'deviceId'),
      hardwareId: json['hardwareId'] as String?,
      releaseId: _string(json, 'releaseId'),
      fromVersion: _string(json, 'fromVersion', allowEmpty: true),
      targetVersion: _string(json, 'targetVersion'),
      state: _enum(FirmwareUpdateState.values, json['state']),
      startedAt: DateTime.parse(_string(json, 'startedAt')),
      updatedAt: DateTime.parse(_string(json, 'updatedAt')),
      completedAt: json['completedAt'] == null
          ? null
          : DateTime.parse(json['completedAt'] as String),
      failureCode: json['failureCode'] as String?,
      failureMessage: json['failureMessage'] as String?,
      nativeTransferEngaged: json['nativeTransferEngaged'] as bool? ?? false,
      requiresRecovery: json['requiresRecovery'] as bool? ?? false,
      schemaVersion: json['schemaVersion'] as int,
      nextAction: _enum(FirmwareUpdateNextAction.values, json['nextAction']),
      reconciliationOutcome: json['reconciliationOutcome'] == null
          ? null
          : _enum(
              FirmwareUpdateReconciliationOutcome.values,
              json['reconciliationOutcome'],
            ),
    );
  }

  T _enum<T extends Enum>(List<T> values, Object? name) {
    if (name is! String) throw const FormatException();
    return values.firstWhere((value) => value.name == name);
  }

  String _string(
    Map<String, dynamic> json,
    String key, {
    bool allowEmpty = false,
  }) {
    final value = json[key];
    if (value is! String || (!allowEmpty && value.isEmpty)) {
      throw const FormatException();
    }
    return value;
  }
}
