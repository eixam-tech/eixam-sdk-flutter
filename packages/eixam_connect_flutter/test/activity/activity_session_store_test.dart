import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart' as public;
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_session_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/sdk/activity_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activity_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Flutter public entrypoint exports model, capability, exception', () {
    expect(
      ActivitySessionController(store: MemoryActivityStore()),
      isA<public.ActivitySessionControl>(),
    );
    const error = public.ActivitySessionException('code', 'message');
    expect(error.code, 'code');
    final public.SdkActivitySession session = SdkActivitySession(
      sessionId: 'a',
      activityKey: 'ski',
      startedAt: DateTime.utc(2026),
    );
    expect(session.activityKey, 'ski');
  });

  test(
    'real SharedPreferences adapter restores across store/controller instances',
    () async {
      SharedPreferences.setMockInitialValues({});
      var controller = ActivitySessionController(
        store: SharedPrefsActivitySessionStore(SharedPrefsSdkStore()),
      );
      await bind(controller, userA);
      final a = await controller.startActivitySession(
        activityKey: 'org.example.paddling',
      );
      await controller.dispose();
      controller = ActivitySessionController(
        store: SharedPrefsActivitySessionStore(SharedPrefsSdkStore()),
      );
      addTearDown(controller.dispose);
      await bind(controller, userA);
      expect(
        (await controller.getActiveActivitySession())?.sessionId,
        a.sessionId,
      );
      await controller.endActivitySession(sessionId: a.sessionId);
      expect(await controller.getActiveActivitySession(), isNull);
      final prefs = await SharedPreferences.getInstance();
      final json = jsonDecode(
        prefs.getString(SharedPrefsSdkStore.activitySessionKey)!,
      );
      expect(json['state'], 'ended');
      expect(json.keys.toSet(), {
        'schemaVersion',
        'ownerScope',
        'sdkUserId',
        'sessionId',
        'activityKey',
        'startedAt',
        'state',
        'endedAt',
      });
    },
  );

  for (final kind in [
    'invalid-json',
    'unsupported',
    'invalid-key',
    'invalid-time',
    'invalid-end',
    'invalid-state',
    'missing-id',
    'empty',
  ]) {
    test('restoration rejects $kind without destroying raw evidence', () async {
      final store = MemoryActivityStore();
      var controller = ActivitySessionController(store: store);
      await bind(controller, userA);
      await controller.startActivitySession(activityKey: 'ski');
      await controller.dispose();
      final json = jsonDecode(store.raw!) as Map<String, dynamic>;
      switch (kind) {
        case 'invalid-json':
          store.raw = '{broken';
        case 'empty':
          store.raw = '';
        case 'unsupported':
          json['schemaVersion'] = 99;
          store.raw = jsonEncode(json);
        case 'invalid-key':
          json['activityKey'] = 'Ski';
          store.raw = jsonEncode(json);
        case 'invalid-time':
          json['startedAt'] = 'invalid';
          store.raw = jsonEncode(json);
        case 'invalid-end':
          json['endedAt'] = DateTime.utc(2026).toIso8601String();
          store.raw = jsonEncode(json);
        case 'invalid-state':
          json['state'] = 'tracking';
          store.raw = jsonEncode(json);
        case 'missing-id':
          json.remove('sessionId');
          store.raw = jsonEncode(json);
      }
      final raw = store.raw;
      controller = ActivitySessionController(store: store);
      addTearDown(controller.dispose);
      await bind(controller, userA);
      await expectLater(
        controller.getActiveActivitySession(),
        throwsA(activityError('E_ACTIVITY_RESTORE_FAILED')),
      );
      await expectLater(
        controller.startActivitySession(activityKey: 'hunting'),
        throwsA(activityError('E_ACTIVITY_RESTORE_FAILED')),
      );
      expect(store.raw, raw);
      await expectLater(
        controller.watchActiveActivitySession(),
        emitsError(activityError('E_ACTIVITY_RESTORE_FAILED')),
      );
    });
  }

  test('unreadable is not missing and can be retried', () async {
    final store = MemoryActivityStore()..unreadable = true;
    final controller = ActivitySessionController(store: store);
    addTearDown(controller.dispose);
    await bind(controller, userA);
    await expectLater(
      controller.getActiveActivitySession(),
      throwsA(activityError('E_ACTIVITY_RESTORE_FAILED')),
    );
    store.unreadable = false;
    expect(await controller.getActiveActivitySession(), isNull);
  });

  test('UTC codec checks lifecycle and unknown keys on decode', () {
    final record = ActivitySessionRecord(
      ownerScope: 'scope',
      session: SdkActivitySession(
        sessionId: 'id',
        activityKey: 'future.custom',
        startedAt: DateTime.utc(2026),
      ),
      endedAt: DateTime.utc(2026, 1, 2),
    );
    final decoded = ActivitySessionRecord.decode(record.encode());
    expect(decoded.active, isNull);
    expect(decoded.session.activityKey, 'future.custom');
    expect(decoded.endedAt, DateTime.utc(2026, 1, 2));
  });
}
