import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/sdk/firmware_update_session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('no active update returns null', () async {
    expect(await SharedPrefsFirmwareUpdateSessionStore().load(), isNull);
  });

  test('creates and restores authoritative OTA context', () async {
    final store = SharedPrefsFirmwareUpdateSessionStore();
    await store.save(_session());

    final restored = await store.load();

    expect(restored?.sessionId, 'fw-1');
    expect(restored?.hardwareId, 'AA:BB:CC:DD:EE:FF');
    expect(restored?.targetVersion, '2.0.0');
    expect(restored?.nativeTransferEngaged, isTrue);
    expect(restored?.requiresRecovery, isTrue);
    expect(restored?.artifactReference, 'cache-reference');
    expect(restored?.artifactSha256, 'sha256');
    expect(restored?.artifactSizeBytes, 123);
    expect(restored?.artifactDownloaded, true);
    expect(restored?.artifactVerified, true);
  });

  test('manual recovery evidence survives a new store instance', () async {
    await SharedPrefsFirmwareUpdateSessionStore().save(
      _session().copyWith(
        state: FirmwareUpdateState.physicalRecoveryRequired,
        nextAction: FirmwareUpdateNextAction.physicalRecovery,
        recoveryDeviceMatched: true,
        remoteRecoveryAttempts: 3,
        remoteRecoveryFailed: true,
        recoveryReconciliationAttempts: 3,
        remoteRecoveryExhausted: true,
      ),
    );
    final restored = await SharedPrefsFirmwareUpdateSessionStore().load();
    expect(restored?.manualRecoveryRequired, isTrue);
    expect(restored?.remoteRecoveryAttempts, 3);
    expect(restored?.recoveryReconciliationAttempts, 3);
    expect(restored?.nextAction, FirmwareUpdateNextAction.physicalRecovery);
  });

  test('metadata resolution intent survives without target version', () async {
    final now = DateTime.now();
    final store = SharedPrefsFirmwareUpdateSessionStore();
    await store.save(
      FirmwareUpdateSession(
        sessionId: 'intent',
        deviceId: 'tag',
        releaseId: 'release',
        fromVersion: '1.0.0',
        targetVersion: '',
        state: FirmwareUpdateState.checking,
        startedAt: now,
      ),
    );
    final restored = await SharedPrefsFirmwareUpdateSessionStore().load();
    expect(restored?.sessionId, 'intent');
    expect(restored?.targetVersion, '');
    expect(restored?.nativeTransferEngaged, false);
  });

  test('malformed record is removed', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SharedPrefsSdkStore.firmwareUpdateSessionKey, '{bad');

    expect(await SharedPrefsFirmwareUpdateSessionStore().load(), isNull);
    expect(
      prefs.containsKey(SharedPrefsSdkStore.firmwareUpdateSessionKey),
      isFalse,
    );
  });

  test('old schema is removed', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      SharedPrefsSdkStore.firmwareUpdateSessionKey,
      jsonEncode(<String, Object>{'schemaVersion': 0}),
    );

    expect(await SharedPrefsFirmwareUpdateSessionStore().load(), isNull);
    expect(
      prefs.containsKey(SharedPrefsSdkStore.firmwareUpdateSessionKey),
      isFalse,
    );
  });

  test('stale completed record is removed', () async {
    final store = SharedPrefsFirmwareUpdateSessionStore();
    await store.save(_session(state: FirmwareUpdateState.completed));

    expect(await store.load(), isNull);
  });
}

FirmwareUpdateSession _session({
  FirmwareUpdateState state = FirmwareUpdateState.recoveryRequired,
}) {
  final now = DateTime.utc(2026, 1, 1);
  return FirmwareUpdateSession(
    sessionId: 'fw-1',
    deviceId: 'device-1',
    hardwareId: 'AA:BB:CC:DD:EE:FF',
    releaseId: 'release-1',
    fromVersion: '1.0.0',
    targetVersion: '2.0.0',
    artifactReference: 'cache-reference',
    artifactSha256: 'sha256',
    artifactSizeBytes: 123,
    artifactDownloaded: true,
    artifactVerified: true,
    state: state,
    startedAt: now,
    updatedAt: now,
    completedAt: state == FirmwareUpdateState.completed ? now : null,
    nativeTransferEngaged: true,
    requiresRecovery: state == FirmwareUpdateState.recoveryRequired,
    nextAction: state == FirmwareUpdateState.completed
        ? FirmwareUpdateNextAction.completed
        : FirmwareUpdateNextAction.recover,
  );
}
