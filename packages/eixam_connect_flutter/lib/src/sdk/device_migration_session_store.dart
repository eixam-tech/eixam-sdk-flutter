import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/shared_prefs_sdk_store.dart';

abstract interface class DeviceMigrationSessionStore {
  Future<DeviceMigrationSession?> load();
  Future<void> save(DeviceMigrationSession session);
  Future<void> clear();
}

final class SharedPrefsDeviceMigrationSessionStore
    implements DeviceMigrationSessionStore {
  SharedPrefsDeviceMigrationSessionStore({SharedPrefsSdkStore? localStore})
    : _localStore = localStore ?? SharedPrefsSdkStore();

  final SharedPrefsSdkStore _localStore;

  @override
  Future<DeviceMigrationSession?> load() async {
    final json = await _localStore.readJson(
      SharedPrefsSdkStore.deviceMigrationSessionKey,
    );
    if (json == null) {
      await clear();
      return null;
    }
    try {
      final schemaVersion = json['schemaVersion'] as int?;
      if (schemaVersion != DeviceMigrationSession.currentSchemaVersion) {
        await clear();
        return null;
      }
      final session = _decode(json);
      if (session.state == DeviceMigrationState.completed) {
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
  Future<void> save(DeviceMigrationSession session) {
    return _localStore.saveJson(
      SharedPrefsSdkStore.deviceMigrationSessionKey,
      _encode(session),
    );
  }

  @override
  Future<void> clear() {
    return _localStore.remove(SharedPrefsSdkStore.deviceMigrationSessionKey);
  }

  Map<String, dynamic> _encode(DeviceMigrationSession session) =>
      <String, dynamic>{
        'schemaVersion': session.schemaVersion,
        'sessionId': session.sessionId,
        'candidate': _encodeCandidate(session.candidate),
        'releaseId': session.releaseId,
        'targetVersion': session.targetVersion,
        'firmwareSession': session.firmwareSession == null
            ? null
            : _encodeFirmwareSession(session.firmwareSession!),
        'migratedDevice': session.migratedDevice == null
            ? null
            : _encodeScan(session.migratedDevice!),
        'state': session.state.name,
        'outcome': session.outcome?.name,
        'reconciliationOutcome': session.reconciliationOutcome?.name,
        'nextAction': session.nextAction.name,
        'canCancel': session.canCancel,
        'failureCode': session.failureCode,
        'createdAt': session.createdAt.toUtc().toIso8601String(),
        'updatedAt': session.updatedAt.toUtc().toIso8601String(),
      };

  DeviceMigrationSession _decode(Map<String, dynamic> json) {
    final candidateJson = json['candidate'];
    if (candidateJson is! Map<String, dynamic>) throw const FormatException();
    return DeviceMigrationSession(
      sessionId: _requiredString(json, 'sessionId'),
      schemaVersion: json['schemaVersion'] as int,
      candidate: _decodeCandidate(candidateJson),
      releaseId: _requiredString(
        json,
        'releaseId',
        allowEmpty:
            json['firmwareSession'] == null &&
            json['state'] == DeviceMigrationState.prepared.name,
      ),
      targetVersion: _requiredString(
        json,
        'targetVersion',
        allowEmpty:
            json['firmwareSession'] == null &&
            json['state'] == DeviceMigrationState.prepared.name,
      ),
      firmwareSession: _optionalMap(json['firmwareSession'], _decodeFirmware),
      migratedDevice: _optionalMap(json['migratedDevice'], _decodeScan),
      state: _enumByName(DeviceMigrationState.values, json['state']),
      outcome: _optionalEnum(DeviceMigrationOutcome.values, json['outcome']),
      reconciliationOutcome: _optionalEnum(
        DeviceMigrationReconciliationOutcome.values,
        json['reconciliationOutcome'],
      ),
      nextAction: _enumByName(
        DeviceMigrationNextAction.values,
        json['nextAction'],
      ),
      canCancel: json['canCancel'] as bool,
      failureCode: json['failureCode'] as String?,
      createdAt: DateTime.parse(_requiredString(json, 'createdAt')),
      updatedAt: DateTime.parse(_requiredString(json, 'updatedAt')),
    );
  }

  Map<String, dynamic> _encodeCandidate(DeviceMigrationCandidate value) =>
      <String, dynamic>{
        'deviceId': value.deviceId,
        'advertisedName': value.advertisedName,
        'compatibility': value.compatibility.name,
        'sourceHardwareModel': value.sourceHardwareModel,
        'sourceFirmwareVersion': value.sourceFirmwareVersion,
        'stableIdentity': value.stableIdentity,
        'identityKind': value.identityKind.name,
        'sourceNodeNumber': value.sourceNodeNumber,
        'batteryPercentage': value.batteryPercentage,
        'detailCode': value.detailCode,
        'inspectionFailure': value.inspectionFailure?.name,
        'inspectedAt': value.inspectedAt.toUtc().toIso8601String(),
      };

  DeviceMigrationCandidate _decodeCandidate(Map<String, dynamic> json) =>
      DeviceMigrationCandidate(
        deviceId: _requiredString(json, 'deviceId'),
        advertisedName: json['advertisedName'] as String?,
        compatibility: _enumByName(
          DeviceMigrationCompatibility.values,
          json['compatibility'],
        ),
        sourceHardwareModel: json['sourceHardwareModel'] as int?,
        sourceFirmwareVersion: json['sourceFirmwareVersion'] as String?,
        stableIdentity: json['stableIdentity'] as String?,
        identityKind: _enumByName(
          DeviceMigrationIdentityKind.values,
          json['identityKind'],
        ),
        sourceNodeNumber: json['sourceNodeNumber'] as int?,
        batteryPercentage: json['batteryPercentage'] as int?,
        detailCode: json['detailCode'] as String?,
        inspectionFailure: json['inspectionFailure'] == null
            ? null
            : _enumByName(
                DeviceMigrationInspectionFailure.values,
                json['inspectionFailure'],
              ),
        inspectedAt: DateTime.parse(_requiredString(json, 'inspectedAt')),
      );

  Map<String, dynamic> _encodeFirmwareSession(FirmwareUpdateSession value) =>
      <String, dynamic>{
        'sessionId': value.sessionId,
        'deviceId': value.deviceId,
        'releaseId': value.releaseId,
        'fromVersion': value.fromVersion,
        'targetVersion': value.targetVersion,
        'state': value.state.name,
        'startedAt': value.startedAt.toUtc().toIso8601String(),
        'completedAt': value.completedAt?.toUtc().toIso8601String(),
        'failureCode': value.failureCode,
        'migrationOwned': value.migrationOwned,
        'artifactReference': value.artifactReference,
        'artifactSha256': value.artifactSha256,
        'artifactSizeBytes': value.artifactSizeBytes,
        'artifactDownloaded': value.artifactDownloaded,
        'artifactVerified': value.artifactVerified,
        'nativeTransferEngaged': value.nativeTransferEngaged,
        'recoveryDeviceMatched': value.recoveryDeviceMatched,
        'remoteRecoveryAttempts': value.remoteRecoveryAttempts,
        'remoteRecoveryFailed': value.remoteRecoveryFailed,
        'recoveryReconciliationAttempts': value.recoveryReconciliationAttempts,
        'remoteRecoveryExhausted': value.remoteRecoveryExhausted,
        'requiresRecovery': value.requiresRecovery,
        'schemaVersion': value.schemaVersion,
        'hardwareId': value.hardwareId,
        'updatedAt': value.updatedAt?.toUtc().toIso8601String(),
        'nextAction': value.nextAction.name,
        'reconciliationOutcome': value.reconciliationOutcome?.name,
      };

  FirmwareUpdateSession _decodeFirmware(Map<String, dynamic> json) =>
      FirmwareUpdateSession(
        sessionId: _requiredString(json, 'sessionId'),
        deviceId: _requiredString(json, 'deviceId'),
        releaseId: _requiredString(json, 'releaseId'),
        fromVersion: _requiredString(json, 'fromVersion'),
        targetVersion: _requiredString(json, 'targetVersion'),
        state: _enumByName(FirmwareUpdateState.values, json['state']),
        startedAt: DateTime.parse(_requiredString(json, 'startedAt')),
        completedAt: (json['completedAt'] as String?) == null
            ? null
            : DateTime.parse(json['completedAt'] as String),
        failureCode: json['failureCode'] as String?,
        migrationOwned: json['migrationOwned'] as bool? ?? true,
        artifactReference: json['artifactReference'] as String?,
        artifactSha256: json['artifactSha256'] as String?,
        artifactSizeBytes: json['artifactSizeBytes'] as int?,
        artifactDownloaded: json['artifactDownloaded'] as bool? ?? false,
        artifactVerified: json['artifactVerified'] as bool? ?? false,
        nativeTransferEngaged: json['nativeTransferEngaged'] as bool? ?? false,
        recoveryDeviceMatched: json['recoveryDeviceMatched'] as bool? ?? false,
        remoteRecoveryAttempts: json['remoteRecoveryAttempts'] as int? ?? 0,
        remoteRecoveryFailed: json['remoteRecoveryFailed'] as bool? ?? false,
        recoveryReconciliationAttempts:
            json['recoveryReconciliationAttempts'] as int? ?? 0,
        remoteRecoveryExhausted:
            json['remoteRecoveryExhausted'] as bool? ?? false,
        requiresRecovery: json['requiresRecovery'] as bool? ?? false,
        schemaVersion:
            json['schemaVersion'] as int? ??
            FirmwareUpdateSession.currentSchemaVersion,
        hardwareId: json['hardwareId'] as String?,
        updatedAt: (json['updatedAt'] as String?) == null
            ? null
            : DateTime.parse(json['updatedAt'] as String),
        nextAction: json['nextAction'] == null
            ? FirmwareUpdateNextAction.none
            : _enumByName(FirmwareUpdateNextAction.values, json['nextAction']),
        reconciliationOutcome: json['reconciliationOutcome'] == null
            ? null
            : _enumByName(
                FirmwareUpdateReconciliationOutcome.values,
                json['reconciliationOutcome'],
              ),
      );

  Map<String, dynamic> _encodeScan(EixamBleScanResult value) =>
      <String, dynamic>{
        'deviceId': value.deviceId,
        'canonicalHardwareId': value.canonicalHardwareId,
        'name': value.name,
        'rssi': value.rssi,
        'connectable': value.connectable,
        'brandClassification': value.brandClassification.name,
        'isEixamDevice': value.isEixamDevice,
        'isDfuBootloader': value.isDfuBootloader,
        'discoveredAt': value.discoveredAt.toUtc().toIso8601String(),
      };

  EixamBleScanResult _decodeScan(Map<String, dynamic> json) =>
      EixamBleScanResult(
        deviceId: _requiredString(json, 'deviceId'),
        canonicalHardwareId: json['canonicalHardwareId'] as String?,
        name: _requiredString(json, 'name'),
        rssi: json['rssi'] as int,
        connectable: json['connectable'] as bool,
        brandClassification: _enumByName(
          BleDiscoveredDeviceBrand.values,
          json['brandClassification'],
        ),
        isEixamDevice: json['isEixamDevice'] as bool,
        isDfuBootloader: json['isDfuBootloader'] as bool? ?? false,
        discoveredAt: DateTime.parse(_requiredString(json, 'discoveredAt')),
      );

  T? _optionalMap<T>(Object? value, T Function(Map<String, dynamic>) decode) {
    if (value == null) return null;
    if (value is! Map<String, dynamic>) throw const FormatException();
    return decode(value);
  }

  T _enumByName<T extends Enum>(List<T> values, Object? name) {
    if (name is! String) throw const FormatException();
    return values.firstWhere((value) => value.name == name);
  }

  T? _optionalEnum<T extends Enum>(List<T> values, Object? name) {
    if (name == null) return null;
    return _enumByName(values, name);
  }

  String _requiredString(
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
