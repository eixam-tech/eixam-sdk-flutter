import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/tag_alert_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  test('key is versioned and registered for checked wipe coverage', () {
    expect(SharedPrefsSdkStore.tagAlertsKey, 'eixam.tag_alerts.v1');
    expect(
      SharedPrefsSdkStore.checkedLocalUserDataKeys,
      contains(SharedPrefsSdkStore.tagAlertsKey),
    );
  });

  test('record round-trips several devices', () {
    final record = TagAlertRecord(
      ownerScope: 'scope',
      devices: {
        'tag-1': TagAlertSettings(deviceId: 'tag-1', disconnectAfter: null),
        'tag-2': TagAlertSettings(
          deviceId: 'tag-2',
          batteryAlerts: false,
          disconnectAfter: const Duration(minutes: 30),
        ),
      },
    );
    final decoded = TagAlertRecord.decode(record.encode());
    expect(decoded.ownerScope, 'scope');
    expect(decoded.devices, record.devices);
  });

  test('record persists only settings and an opaque scope', () {
    final record = TagAlertRecord(
      ownerScope: 'scope',
      devices: {'tag-1': TagAlertSettings(deviceId: 'tag-1')},
    );
    final json = jsonDecode(record.encode()) as Map<String, Object?>;
    expect(json.keys.toSet(), {'v', 'ownerScope', 'devices'});
  });

  test('decode rejects malformed, newer and inconsistent envelopes', () {
    final good =
        jsonDecode(
              TagAlertRecord(
                ownerScope: 's',
                devices: {'a': TagAlertSettings(deviceId: 'a')},
              ).encode(),
            )
            as Map<String, Object?>;
    final bad = <String>[
      'not json',
      '[]',
      jsonEncode({...good, 'v': 2}),
      jsonEncode({...good, 'ownerScope': ''}),
      jsonEncode({...good, 'devices': 'x'}),
      jsonEncode({
        ...good,
        'devices': {'other': TagAlertSettings(deviceId: 'a').toJson()},
      }),
      jsonEncode({
        ...good,
        'devices': {
          'a': {...TagAlertSettings(deviceId: 'a').toJson(), 'v': 9},
        },
      }),
    ];
    for (final raw in bad) {
      expect(
        () => TagAlertRecord.decode(raw),
        throwsA(anyOf(isA<FormatException>(), isA<TypeError>())),
        reason: raw,
      );
    }
  });

  test(
    'shared-prefs store reads, writes and removes its own key only',
    () async {
      final backing = MemorySharedPrefsSdkStore();
      backing.stringValues['other'] = 'keep';
      final store = SharedPrefsTagAlertStore(backing);
      expect(await store.read(), isNull);
      expect(await store.write('x'), isTrue);
      expect(backing.stringValues[SharedPrefsSdkStore.tagAlertsKey], 'x');
      expect(await store.read(), 'x');
      expect(await store.remove(), isTrue);
      expect(backing.stringValues, {'other': 'keep'});
    },
  );
}
