import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guards for the native DFU bridges. The native options cannot run in
/// unit tests; these pin the decisions that keep an interrupted legacy DFU
/// recoverable and prove the iOS flow changed only where documented.
String code(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//.*'), '');

void main() {
  final kotlin = code(
    File(
      'android/src/main/kotlin/dev/eixam/connect/flutter/dfu/FirmwareDfuBridge.kt',
    ).readAsStringSync(),
  );
  final service = code(
    File(
      'android/src/main/kotlin/dev/eixam/connect/flutter/dfu/EixamDfuService.kt',
    ).readAsStringSync(),
  );
  final swift = code(
    File('ios/Classes/FirmwareDfuBridge.swift').readAsStringSync(),
  );

  group('Android', () {
    test('no in-session DFU retry', () {
      expect(kotlin, contains('.setNumberOfRetries(0)'));
      expect(kotlin, isNot(contains('.setNumberOfRetries(3)')));
    });

    test('plugin detach never aborts the Nordic service', () {
      final unregister = kotlin.substring(
        kotlin.indexOf('fun unregister()'),
        kotlin.indexOf('private fun handleMethodCall'),
      );
      expect(unregister, isNot(contains('abort()')));
    });

    test('the only remaining abort() is the explicit pre-engage cancel', () {
      expect('abort()'.allMatches(kotlin).length, 1);
      final cancel = kotlin.substring(kotlin.indexOf('private fun cancelDfu'));
      expect(cancel, contains('abort()'));
    });

    test('task removal does not stop the transfer', () {
      expect(service, contains('override fun onTaskRemoved'));
      expect(service, isNot(contains('stopSelf')));
      expect(service, isNot(contains('super.onTaskRemoved')));
    });

    test('flow control and bonding options are unchanged', () {
      expect(kotlin, contains('.setPacketsReceiptNotificationsEnabled(true)'));
      expect(kotlin, contains('.setPacketsReceiptNotificationsValue(8)'));
      expect(kotlin, contains('.setKeepBond(true)'));
      expect(kotlin, contains('.setForeground(true)'));
      expect(kotlin, contains('.setForceDfu(forceDfu)'));
      expect(kotlin, isNot(contains('forceScanningForNewAddress')));
    });

    test('DFU debug logging stays off', () {
      expect(service, contains('override fun isDebug(): Boolean = false'));
    });
  });

  group('iOS (only documented changes)', () {
    test('existing options are unchanged', () {
      expect(swift, contains('packetReceiptNotificationParameter = 8'));
      expect(
        swift,
        contains('enableUnsafeExperimentalButtonlessServiceInSecureDfu = true'),
      );
      expect(swift, contains('dataObjectPreparationDelay = 0.3'));
      expect(swift, contains('initiator.forceDfu = pending.forceDfu'));
      expect(swift, isNot(contains('forceScanningForNewAddress')));
    });

    test('documented change: connection timeout is 30 s', () {
      expect(swift, contains('initiator.connectionTimeout = 30'));
    });

    test('abort() exists only in the explicit cancel path', () {
      expect('abort()'.allMatches(swift).length, 1);
      final cancel = swift.substring(swift.indexOf('private func cancelDfu'));
      expect(cancel, contains('abort()'));
    });
  });

  group('no automatic DFU', () {
    final libSources = <String, String>{
      for (final entity in Directory('lib/src').listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart'))
          entity.path: code(entity.readAsStringSync()),
    };

    test('forceDfu: true appears only in the explicit recovery start', () {
      final hits = libSources.entries
          .where((entry) => entry.value.contains('forceDfu: true'))
          .map((entry) => entry.key)
          .toList();
      expect(hits, ['lib/src/sdk/firmware_update_coordinator.dart']);
      expect('forceDfu: true'.allMatches(libSources[hits.single]!).length, 1);
    });

    test(
      'only the user-started controller starts a bootloader recovery DFU',
      () {
        final callers = libSources.entries
            .where(
              (entry) => entry.value.contains('startBootloaderRecoveryDfu('),
            )
            .map((entry) => entry.key)
            .toSet();
        expect(callers, {
          'lib/src/sdk/firmware_update_coordinator.dart',
          'lib/src/sdk/dfu_recovery_controller.dart',
        });
      },
    );

    test('the old automatic recovery entry points are gone', () {
      final all = libSources.values.join('\n');
      expect(all, isNot(contains('recoverMigrationFirmwareUpdate')));
      expect(all, isNot(contains('_recoverFirmwareUpdate(')));
      expect(all, isNot(contains('maxRecoveryReconciliations);\n')));
    });
  });

  test('the BLE restore after a DFU does not wait for the reconnect '
      'campaign (P5 F3: cable preparation held E2 for ~2 min)', () {
    final impl = code(
      File('lib/src/sdk/eixam_connect_sdk_impl.dart').readAsStringSync(),
    );
    final restore = impl.substring(
      impl.indexOf('Future<void> restoreBleAfterFirmwareDfuTransfer('),
      impl.indexOf(
        'Future<DeviceStatus> refreshFirmwareDfuInstalledVersionStatus(',
      ),
    );
    expect(restore, contains('tryAutoConnectOnResume()'));
    expect(
      restore,
      isNot(
        contains('await _bleAutoReconnectCoordinator.tryAutoConnectOnResume'),
      ),
    );
    // The post-DFU version check still waits for the reconnect.
    final verify = impl.substring(
      impl.indexOf(
        'Future<DeviceStatus> refreshFirmwareDfuInstalledVersionStatus(',
      ),
    );
    expect(
      verify.substring(0, 400),
      contains('await _bleAutoReconnectCoordinator.tryAutoConnectOnResume()'),
    );
  });
}
