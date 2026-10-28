import 'dart:async';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/android_location_permissions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, dynamic> os;
  late List<String> calls;
  late AndroidLocationPermissions permissions;
  setUp(() {
    calls = [];
    os = {
      'apiLevel': 36,
      'foregroundGranted': false,
      'backgroundGranted': false,
      'preciseGranted': false,
      'locationServicesEnabled': true,
      'foregroundRequested': false,
      'foregroundRequestAvailable': true,
      'backgroundRequestAvailable': false,
      'backgroundPermissionOptionLabel': 'Permet sempre',
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return os;
    });
    permissions = AndroidLocationPermissions(channel: channel);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('fresh install and denied/settingsRequired are distinct', () async {
    var state = await permissions.getState();
    expect(
      state.permission.authorizationStatus,
      LocationAuthorizationStatus.notDetermined,
    );
    expect(state.settingsRequired, isFalse);
    os['foregroundRequested'] = true;
    os['foregroundRequestAvailable'] = false;
    state = await permissions.getState();
    expect(
      state.permission.authorizationStatus,
      LocationAuthorizationStatus.denied,
    );
    expect(state.settingsRequired, isTrue);
    expect(calls, ['getState', 'getState']);
  });
  test(
    'approximate and precise foreground never imply permanent readiness',
    () async {
      os['foregroundGranted'] = true;
      os['backgroundRequestAvailable'] = true;
      var state = await permissions.getState();
      expect(state.permission.isForegroundLocationUsable, isTrue);
      expect(
        state.permission.accuracyAuthorization,
        LocationAccuracyAuthorization.reduced,
      );
      expect(state.permission.isBackgroundLocationUsable, isFalse);
      expect(state.temporarilyGranted, isNull);
      expect(state.backgroundRequestAvailable, isTrue);
      expect(state.backgroundPermissionOptionLabel, 'Permet sempre');
      os['preciseGranted'] = true;
      state = await permissions.getState();
      expect(
        state.permission.accuracyAuthorization,
        LocationAccuracyAuthorization.full,
      );
      expect(state.permission.isBackgroundLocationUsable, isFalse);
    },
  );
  test(
    'background denial yields settings recovery without another UI action',
    () async {
      os['foregroundGranted'] = true;
      final state = await permissions.requestBackground();
      expect(state.settingsRequired, isTrue);
      expect(calls, ['requestBackground']);
    },
  );
  test(
    'return and restart re-read OS truth including revoked temporary grants',
    () async {
      os['foregroundGranted'] = true;
      os['backgroundGranted'] = true;
      expect(
        (await permissions.requestBackground())
            .permission
            .isBackgroundLocationUsable,
        isTrue,
      );
      os['backgroundGranted'] = false;
      os['foregroundGranted'] = false;
      expect(
        (await permissions.getState()).permission.isForegroundLocationUsable,
        isFalse,
      );
      final restarted = AndroidLocationPermissions(channel: channel);
      expect(
        (await restarted.getState()).permission.isBackgroundLocationUsable,
        isFalse,
      );
      expect(calls, ['requestBackground', 'getState', 'getState']);
    },
  );
  test('disabled services are not usable even with permission', () async {
    os['foregroundGranted'] = true;
    os['backgroundGranted'] = true;
    os['locationServicesEnabled'] = false;
    expect(
      (await permissions.getState()).permission.isBackgroundLocationUsable,
      isFalse,
    );
  });
  test('overlapping user actions share one pending native operation', () async {
    final result = Completer<Map<String, dynamic>>();
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call.method);
      return result.future;
    });
    final first = permissions.requestForeground();
    final second = permissions.requestForeground();
    expect(identical(first, second), isTrue);
    result.complete(os);
    await Future.wait([first, second]);
    expect(calls, ['requestForeground']);
  });
  test(
    'conflicting foreground/background actions fail instead of sharing a result',
    () async {
      final result = Completer<Map<String, dynamic>>();
      messenger.setMockMethodCallHandler(channel, (_) => result.future);
      final foreground = permissions.requestForeground();
      await expectLater(permissions.requestBackground(), throwsStateError);
      result.complete(os);
      await foreground;
    },
  );

  test(
    'native errors clear pending action for later explicit intent',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'location_permission_ui_unavailable');
      });
      await expectLater(
        permissions.requestBackground(),
        throwsA(isA<PlatformException>()),
      );
      messenger.setMockMethodCallHandler(channel, (_) async => os);
      expect((await permissions.requestBackground()).apiLevel, 36);
    },
  );
}
