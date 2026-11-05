import '../data/datasources_local/shared_prefs_sdk_store.dart';

/// Small durable record behind `DfuRecoveryControl`. It holds only timestamps
/// and ids (no payloads); the interrupted firmware session itself stays in the
/// firmware session store.
class DfuRecoveryRecord {
  const DfuRecoveryRecord({
    this.sessionId,
    this.firstMissAt,
    this.cablePreparedAt,
    this.recoveredAt,
    this.dismissedSessionId,
    this.staleLinkDeviceId,
    this.staleLinkAt,
  });

  /// Interrupted firmware session the timestamps below belong to.
  final String? sessionId;

  /// First scan that did not see the TAG in any mode (cleared on a sighting).
  final DateTime? firstMissAt;

  /// The user-started cable preparation ended with the TAG gone from the air.
  final DateTime? cablePreparedAt;

  /// Reconnect + installed version verified (latched until dismissed).
  final DateTime? recoveredAt;
  final String? dismissedSessionId;

  /// iOS connect failed with the stale bond/GATT cache signature.
  final String? staleLinkDeviceId;
  final DateTime? staleLinkAt;

  DfuRecoveryRecord copyWith({
    String? sessionId,
    DateTime? firstMissAt,
    bool clearFirstMiss = false,
    DateTime? cablePreparedAt,
    bool clearCablePrepared = false,
    DateTime? recoveredAt,
    bool clearRecovered = false,
    String? dismissedSessionId,
    String? staleLinkDeviceId,
    DateTime? staleLinkAt,
    bool clearStaleLink = false,
  }) {
    return DfuRecoveryRecord(
      sessionId: sessionId ?? this.sessionId,
      firstMissAt: clearFirstMiss ? null : (firstMissAt ?? this.firstMissAt),
      cablePreparedAt: clearCablePrepared
          ? null
          : (cablePreparedAt ?? this.cablePreparedAt),
      recoveredAt: clearRecovered ? null : (recoveredAt ?? this.recoveredAt),
      dismissedSessionId: dismissedSessionId ?? this.dismissedSessionId,
      staleLinkDeviceId: clearStaleLink
          ? null
          : (staleLinkDeviceId ?? this.staleLinkDeviceId),
      staleLinkAt: clearStaleLink ? null : (staleLinkAt ?? this.staleLinkAt),
    );
  }

  bool get isEmpty =>
      sessionId == null &&
      firstMissAt == null &&
      cablePreparedAt == null &&
      recoveredAt == null &&
      dismissedSessionId == null &&
      staleLinkDeviceId == null;
}

abstract interface class DfuRecoveryRecordStore {
  Future<DfuRecoveryRecord> load();
  Future<void> save(DfuRecoveryRecord record);
}

final class InMemoryDfuRecoveryRecordStore implements DfuRecoveryRecordStore {
  DfuRecoveryRecord record = const DfuRecoveryRecord();

  @override
  Future<DfuRecoveryRecord> load() async => record;

  @override
  Future<void> save(DfuRecoveryRecord record) async => this.record = record;
}

final class SharedPrefsDfuRecoveryRecordStore
    implements DfuRecoveryRecordStore {
  SharedPrefsDfuRecoveryRecordStore({SharedPrefsSdkStore? localStore})
    : _localStore = localStore ?? SharedPrefsSdkStore();

  final SharedPrefsSdkStore _localStore;

  @override
  Future<DfuRecoveryRecord> load() async {
    final json = await _localStore.readJson(
      SharedPrefsSdkStore.dfuRecoveryRecordKey,
    );
    if (json == null) return const DfuRecoveryRecord();
    DateTime? time(String key) {
      final raw = json[key];
      return raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
    }

    return DfuRecoveryRecord(
      sessionId: json['sessionId'] as String?,
      firstMissAt: time('firstMissAt'),
      cablePreparedAt: time('cablePreparedAt'),
      recoveredAt: time('recoveredAt'),
      dismissedSessionId: json['dismissedSessionId'] as String?,
      staleLinkDeviceId: json['staleLinkDeviceId'] as String?,
      staleLinkAt: time('staleLinkAt'),
    );
  }

  @override
  Future<void> save(DfuRecoveryRecord record) async {
    if (record.isEmpty) {
      await _localStore.remove(SharedPrefsSdkStore.dfuRecoveryRecordKey);
      return;
    }
    await _localStore.saveJson(SharedPrefsSdkStore.dfuRecoveryRecordKey, {
      'sessionId': record.sessionId,
      'firstMissAt': record.firstMissAt?.toUtc().toIso8601String(),
      'cablePreparedAt': record.cablePreparedAt?.toUtc().toIso8601String(),
      'recoveredAt': record.recoveredAt?.toUtc().toIso8601String(),
      'dismissedSessionId': record.dismissedSessionId,
      'staleLinkDeviceId': record.staleLinkDeviceId,
      'staleLinkAt': record.staleLinkAt?.toUtc().toIso8601String(),
    });
  }
}
