import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/sdk/device_migration_session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('retired history is read without activating or rewriting it', () async {
    final store = SharedPrefsDeviceMigrationSessionStore();
    final session = _session().copyWith(
      migratedDevice: EixamBleScanResult(
        deviceId: 'target',
        name: 'EIXAM_A6DDEEFF',
        rssi: -60,
        connectable: true,
        isEixamDevice: true,
        brandClassification: BleDiscoveredDeviceBrand.eixam,
        discoveredAt: DateTime.utc(2026),
      ),
    );
    await store.archive(session);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(
      '${SharedPrefsSdkStore.deviceMigrationSessionKey}.retired.malformed',
      42,
    );
    expect(
      (await store.loadRetiredForDevice('target')).single.sessionId,
      session.sessionId,
    );
    expect(await store.loadRetiredForDevice('another-target'), isEmpty);
    expect(await store.load(), isNull);
  });

  test('exact migration identity policy survives restart', () async {
    final store = SharedPrefsDeviceMigrationSessionStore();
    final session = _session(
      verificationPolicy: FirmwareVerificationPolicy.exactCandidate,
    );
    await store.save(session.copyWith(canCancel: false));
    expect(
      (await store.load())?.verificationPolicy,
      FirmwareVerificationPolicy.exactCandidate,
    );
  });

  test(
    'failed pre-artifact intent and recovery deadline survive process death',
    () async {
      final now = DateTime.now();
      final initial = _session();
      final failed = DeviceMigrationSession(
        sessionId: initial.sessionId,
        schemaVersion: DeviceMigrationSession.currentSchemaVersion,
        candidate: initial.candidate,
        releaseId: '',
        targetVersion: '',
        state: DeviceMigrationState.failed,
        nextAction: DeviceMigrationNextAction.retry,
        outcome: DeviceMigrationOutcome.failed,
        failureCode: 'migrationArtifactUnavailable',
        canCancel: false,
        createdAt: now,
        updatedAt: now,
        reconciliationDeadline: now.add(const Duration(minutes: 3)),
      );
      final store = SharedPrefsDeviceMigrationSessionStore();
      await store.save(failed);
      final restored = await SharedPrefsDeviceMigrationSessionStore().load();
      expect(restored?.failureCode, failed.failureCode);
      expect(restored?.releaseId, isEmpty);
      expect(restored?.state, DeviceMigrationState.failed);
      expect(
        restored?.reconciliationDeadline,
        failed.reconciliationDeadline?.toUtc(),
      );
    },
  );

  test(
    'Bluetooth repair state and exact manufacturing identity survive restart',
    () async {
      final store = SharedPrefsDeviceMigrationSessionStore();
      await store.save(
        _session().copyWith(
          state: DeviceMigrationState.bluetoothRepairRequired,
          nextAction: DeviceMigrationNextAction.repairBluetooth,
          canCancel: false,
          failureCode: 'bluetoothBondRepairRequired',
        ),
      );
      final restored = await SharedPrefsDeviceMigrationSessionStore().load();
      expect(restored!.state, DeviceMigrationState.bluetoothRepairRequired);
      expect(restored.nextAction, DeviceMigrationNextAction.repairBluetooth);
      expect(restored.expectedEixamAdvertisingName, 'EIXAM_A6DDEEFF');
      expect(restored.isTerminal, isFalse);
      expect(restored.canCancel, isFalse);
    },
  );

  test('no record returns no active migration', () async {
    final store = SharedPrefsDeviceMigrationSessionStore();

    expect(await store.load(), isNull);
  });

  test('session is saved and restored without secrets', () async {
    final store = SharedPrefsDeviceMigrationSessionStore();
    final session = _session();

    await store.save(session);

    final restored = await store.load();
    expect(restored?.sessionId, session.sessionId);
    expect(restored?.candidate.stableIdentity, 'AA:BB:CC:DD:EE:FF');
    expect(restored?.targetVersion, '3.0.0');
    expect(restored?.nextAction, DeviceMigrationNextAction.continueMigration);
    final raw = (await SharedPreferences.getInstance()).getString(
      SharedPrefsSdkStore.deviceMigrationSessionKey,
    );
    expect(raw, isNot(contains('psk')));
    expect(raw, isNot(contains('credential')));
  });

  test(
    'typed inspection detail survives persistence and older records remain readable',
    () async {
      final store = SharedPrefsDeviceMigrationSessionStore();
      await store.save(_session());
      final prefs = await SharedPreferences.getInstance();
      final raw =
          jsonDecode(
                prefs.getString(SharedPrefsSdkStore.deviceMigrationSessionKey)!,
              )
              as Map<String, dynamic>;
      final candidate = raw['candidate'] as Map<String, dynamic>;
      candidate['inspectionFailure'] = 'bondingTimedOut';
      await prefs.setString(
        SharedPrefsSdkStore.deviceMigrationSessionKey,
        jsonEncode(raw),
      );
      expect(
        (await store.load())?.candidate.inspectionFailure,
        DeviceMigrationInspectionFailure.bondingTimedOut,
      );
      candidate.remove('inspectionFailure');
      await prefs.setString(
        SharedPrefsSdkStore.deviceMigrationSessionKey,
        jsonEncode(raw),
      );
      expect((await store.load())?.candidate.inspectionFailure, isNull);
    },
  );

  test('malformed record is rejected and removed', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      SharedPrefsSdkStore.deviceMigrationSessionKey,
      '{not-json',
    );

    expect(await SharedPrefsDeviceMigrationSessionStore().load(), isNull);
    expect(
      prefs.containsKey(SharedPrefsSdkStore.deviceMigrationSessionKey),
      isFalse,
    );
  });

  test('older schema is rejected and removed', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      SharedPrefsSdkStore.deviceMigrationSessionKey,
      jsonEncode(<String, Object>{'schemaVersion': 0}),
    );

    expect(await SharedPrefsDeviceMigrationSessionStore().load(), isNull);
    expect(
      prefs.containsKey(SharedPrefsSdkStore.deviceMigrationSessionKey),
      isFalse,
    );
  });

  test(
    'archive preserves original recovery evidence after active record is released',
    () async {
      final store = SharedPrefsDeviceMigrationSessionStore();
      final original = _session(
        state: DeviceMigrationState.failed,
        nextAction: DeviceMigrationNextAction.retry,
      );
      await store.save(original);
      await store.archive(original);
      await store.clear();
      expect(await store.load(), isNull);
      final prefs = await SharedPreferences.getInstance();
      final archive = prefs.getString(
        '${SharedPrefsSdkStore.deviceMigrationSessionKey}.retired.${original.sessionId}',
      );
      expect(archive, contains(original.candidate.deviceId));
      expect(archive, contains(original.sessionId));
    },
  );

  test('completed record remains available for setup handoff', () async {
    final store = SharedPrefsDeviceMigrationSessionStore();
    await store.save(
      _session(
        state: DeviceMigrationState.completed,
        nextAction: DeviceMigrationNextAction.completed,
      ),
    );

    expect((await store.load())?.state, DeviceMigrationState.completed);
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        SharedPrefsSdkStore.deviceMigrationSessionKey,
      ),
      isTrue,
    );
  });
}

DeviceMigrationSession _session({
  FirmwareVerificationPolicy verificationPolicy =
      FirmwareVerificationPolicy.normal,
  DeviceMigrationState state = DeviceMigrationState.prepared,
  DeviceMigrationNextAction nextAction =
      DeviceMigrationNextAction.continueMigration,
}) {
  final now = DateTime.utc(2026, 1, 1);
  return DeviceMigrationSession(
    sessionId: 'migration-1',
    schemaVersion: DeviceMigrationSession.currentSchemaVersion,
    candidate: DeviceMigrationCandidate(
      deviceId: 'source-id',
      advertisedName: 'Meshtastic_EEFF',
      compatibility: DeviceMigrationCompatibility.compatible,
      sourceHardwareModel: 105,
      sourceFirmwareVersion: '2.5.0',
      stableIdentity: 'AA:BB:CC:DD:EE:FF',
      identityKind: DeviceMigrationIdentityKind.hardwareMac,
      inspectedAt: now,
    ),
    releaseId: 'release-1',
    targetVersion: '3.0.0',
    verificationPolicy: verificationPolicy,
    state: state,
    nextAction: nextAction,
    canCancel: state == DeviceMigrationState.prepared,
    createdAt: now,
    updatedAt: now,
  );
}
