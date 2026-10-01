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

  test('completed record is stale and removed on restore', () async {
    final store = SharedPrefsDeviceMigrationSessionStore();
    await store.save(
      _session(
        state: DeviceMigrationState.completed,
        nextAction: DeviceMigrationNextAction.completed,
      ),
    );

    expect(await store.load(), isNull);
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        SharedPrefsSdkStore.deviceMigrationSessionKey,
      ),
      isFalse,
    );
  });
}

DeviceMigrationSession _session({
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
    state: state,
    nextAction: nextAction,
    canCancel: state == DeviceMigrationState.prepared,
    createdAt: now,
    updatedAt: now,
  );
}
