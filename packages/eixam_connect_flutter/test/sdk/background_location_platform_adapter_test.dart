import 'dart:async';

import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/sdk/background_location_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/background_location_platform_adapter_factory.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(
    'dev.eixam.connect_flutter/background_location/test_methods',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  test('factory selects native iOS adapter and leaves non-iOS unsupported', () {
    expect(
      buildDefaultBackgroundLocationPlatformAdapter(
        platform: TargetPlatform.iOS,
        isWeb: false,
      ),
      isA<IosBackgroundLocationPlatformAdapter>(),
    );
    expect(
      buildDefaultBackgroundLocationPlatformAdapter(
        platform: TargetPlatform.android,
        isWeb: false,
      ),
      isA<UnsupportedBackgroundLocationPlatformAdapter>(),
    );
    expect(
      buildDefaultBackgroundLocationPlatformAdapter(
        platform: TargetPlatform.macOS,
        isWeb: false,
      ),
      isA<UnsupportedBackgroundLocationPlatformAdapter>(),
    );
  });

  test('concrete SDK exposes the optional capability without changing Core',
      () {
    _requiresBackgroundLocationControl<EixamConnectSdkImpl>();
  });

  test('maps authorization and accuracy permission snapshots', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (_) async {
      return <String, Object?>{
        'locationServicesEnabled': true,
        'authorization': 'always',
        'accuracyAuthorization': 'reduced',
      };
    });
    final adapter = IosBackgroundLocationPlatformAdapter(
      methodChannel: methodChannel,
    );

    final permission = await adapter.getLocationPermissionSnapshot();

    expect(permission.locationServicesEnabled, isTrue);
    expect(
      permission.authorizationStatus,
      LocationAuthorizationStatus.always,
    );
    expect(
      permission.accuracyAuthorization,
      LocationAccuracyAuthorization.reduced,
    );
    await adapter.dispose();
  });

  test('uses distinct explicit permission request methods', () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
      methods.add(call.method);
      return <String, Object?>{
        'locationServicesEnabled': true,
        'authorization': call.method == 'requestLocationAlwaysPermission'
            ? 'always'
            : 'whenInUse',
        'accuracyAuthorization': 'full',
      };
    });
    final adapter = IosBackgroundLocationPlatformAdapter(
      methodChannel: methodChannel,
    );

    await adapter.requestLocationWhenInUsePermission();
    await adapter.requestLocationAlwaysPermission();

    expect(methods, <String>[
      'requestLocationWhenInUsePermission',
      'requestLocationAlwaysPermission',
    ]);
    await adapter.dispose();
  });

  test('rejects invalid typed native payloads explicitly', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (_) async {
      return <String, Object?>{
        ..._validStatus(),
        'permission': <String, Object?>{
          'locationServicesEnabled': true,
          'authorization': 'invented',
          'accuracyAuthorization': 'full',
        },
      };
    });
    final adapter = IosBackgroundLocationPlatformAdapter(
      methodChannel: methodChannel,
    );

    await expectLater(
      adapter.getBackgroundLocationStatus(),
      throwsA(
        isA<BackgroundLocationAdapterException>().having(
          (error) => error.code,
          'code',
          'invalid_native_payload',
        ),
      ),
    );
    await adapter.dispose();
  });

  test('preserves native configuration errors for host recovery', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (_) async {
      throw PlatformException(
        code: 'host_configuration_missing',
        message: 'The host app is missing background location configuration.',
      );
    });
    final adapter = IosBackgroundLocationPlatformAdapter(
      methodChannel: methodChannel,
    );

    await expectLater(
      adapter.requestLocationAlwaysPermission(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'host_configuration_missing',
        ),
      ),
    );
    await adapter.dispose();
  });

  test('sends requested contexts and canonical effective mode', () async {
    var contexts = <String>[];
    var effectiveMode = 'idle';
    final stateCalls = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == 'getBackgroundLocationStatus') {
        return _validStatus(
          activeContexts: contexts,
          effectiveMode: effectiveMode,
        );
      }
      if (call.method == 'setBackgroundLocationState') {
        final arguments = call.arguments as Map<Object?, Object?>;
        stateCalls.add(arguments);
        contexts =
            (arguments['requestedContexts'] as List<Object?>).cast<String>();
        effectiveMode = arguments['effectiveMode'] as String;
        return _validStatus(
          activeContexts: contexts,
          effectiveMode: effectiveMode,
        );
      }
      fail('Unexpected native method ${call.method}.');
    });
    final adapter = IosBackgroundLocationPlatformAdapter(
      methodChannel: methodChannel,
    );

    await adapter.setBackgroundLocationContext(
      BackgroundLocationContext.sharing,
      active: true,
    );
    await adapter.setBackgroundLocationContext(
      BackgroundLocationContext.sos,
      active: true,
    );
    final status = await adapter.setBackgroundLocationContext(
      BackgroundLocationContext.sos,
      active: false,
    );

    expect(stateCalls[0]['effectiveMode'], 'sharing');
    expect(stateCalls[1]['effectiveMode'], 'sos');
    expect(stateCalls[2]['effectiveMode'], 'sharing');
    expect(status.activeContexts, {BackgroundLocationContext.sharing});
    expect(
      () => status.activeContexts.add(BackgroundLocationContext.dmp),
      throwsUnsupportedError,
    );
    await adapter.dispose();
  });

  test('status stream maps initial and update events with one subscription',
      () async {
    final nativeEvents = StreamController<Object?>.broadcast();
    var factoryCalls = 0;
    final adapter = IosBackgroundLocationPlatformAdapter(
      methodChannel: methodChannel,
      eventStreamFactory: () {
        factoryCalls += 1;
        return nativeEvents.stream;
      },
    );
    final first = <BackgroundLocationRuntimeStatus>[];
    final second = <BackgroundLocationRuntimeStatus>[];
    final firstSub = adapter.watchBackgroundLocationStatus().listen(first.add);
    final secondSub =
        adapter.watchBackgroundLocationStatus().listen(second.add);

    nativeEvents.add(_validStatus());
    nativeEvents.add(_validStatus(
      activeContexts: <String>['dmp'],
      effectiveMode: 'dmp',
      running: true,
    ));
    await pumpEventQueue();

    expect(factoryCalls, 1);
    expect(first, hasLength(2));
    expect(second, hasLength(2));
    expect(first.last.effectiveMode, BackgroundLocationMode.dmp);

    await adapter.dispose();
    expect(nativeEvents.hasListener, isFalse);
    expect(
      adapter.watchBackgroundLocationStatus,
      throwsStateError,
    );
    await firstSub.cancel();
    await secondSub.cancel();
    await nativeEvents.close();
  });

  test(
      'location stream validates, dedupes, rejects older samples, and replays latest',
      () async {
    final nativeEvents = StreamController<Object?>.broadcast();
    var factoryCalls = 0;
    final adapter = IosBackgroundLocationPlatformAdapter(
      methodChannel: methodChannel,
      eventStreamFactory: () {
        factoryCalls += 1;
        return nativeEvents.stream;
      },
    );
    final emitted = <IosBackgroundLocationSample>[];
    final firstSub = adapter.watchLocationSamples().listen(emitted.add);
    await pumpEventQueue();
    final newestTimestamp = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
      isUtc: true,
    );
    final newest = _validStatus(
      sample: _sample(
        latitude: 41.3874,
        longitude: 2.1686,
        timestamp: newestTimestamp,
        context: 'combined',
      ),
    );

    nativeEvents.add(newest);
    nativeEvents.add(newest);
    nativeEvents.add(_validStatus(
      sample: _sample(
        latitude: 40,
        longitude: 2,
        timestamp: newestTimestamp.subtract(const Duration(seconds: 1)),
        context: 'sharing',
      ),
    ));
    nativeEvents.add(_validStatus(
      sample: _sample(
        latitude: 91,
        longitude: 2,
        timestamp: newestTimestamp.add(const Duration(seconds: 1)),
        context: 'sos',
      ),
    ));
    await pumpEventQueue();

    expect(factoryCalls, 1);
    expect(emitted, hasLength(1));
    expect(emitted.single.latitude, 41.3874);
    expect(emitted.single.context, 'combined');

    final replayed = await adapter.watchLocationSamples().first;
    expect(replayed.timestamp, newestTimestamp);
    expect(factoryCalls, 1);

    await firstSub.cancel();
    await adapter.dispose();
    await nativeEvents.close();
  });

  test('location stream preserves sharing and SOS sample categories', () async {
    final nativeEvents = StreamController<Object?>.broadcast();
    final adapter = IosBackgroundLocationPlatformAdapter(
      methodChannel: methodChannel,
      eventStreamFactory: () => nativeEvents.stream,
    );
    final contexts = <String>[];
    final subscription =
        adapter.watchLocationSamples().map((sample) => sample.context).listen(
              contexts.add,
            );
    await pumpEventQueue();
    final timestamp = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
      isUtc: true,
    );

    nativeEvents.add(_validStatus(
      sample: _sample(
        latitude: 41,
        longitude: 2,
        timestamp: timestamp,
        context: 'sharing',
      ),
    ));
    nativeEvents.add(_validStatus(
      sample: _sample(
        latitude: 41.1,
        longitude: 2.1,
        timestamp: timestamp.add(const Duration(seconds: 1)),
        context: 'sos',
      ),
    ));
    await pumpEventQueue();

    expect(contexts, <String>['sharing', 'sos']);
    await subscription.cancel();
    await adapter.dispose();
    await nativeEvents.close();
  });

  test('unsupported adapter preserves contexts and reports stable error',
      () async {
    final adapter = UnsupportedBackgroundLocationPlatformAdapter();

    final status = await adapter.setBackgroundLocationContext(
      BackgroundLocationContext.dmp,
      active: true,
    );

    expect(status.isNativePlatformSupported, isFalse);
    expect(status.isNativeServiceRunning, isFalse);
    expect(status.activeContexts, {BackgroundLocationContext.dmp});
    expect(status.lastErrorCode, 'unsupported_platform');
    await expectLater(
      adapter.watchBackgroundLocationStatus(),
      emits(status),
    );
    await adapter.dispose();
  });
}

void
    _requiresBackgroundLocationControl<T extends BackgroundLocationControl>() {}

Map<String, Object?> _validStatus({
  List<String> activeContexts = const <String>[],
  String effectiveMode = 'idle',
  bool running = false,
  Map<String, Object?>? sample,
}) {
  return <String, Object?>{
    'activeContexts': activeContexts,
    'effectiveMode': effectiveMode,
    'isNativePlatformSupported': true,
    'isNativeServiceRunning': running,
    'permission': <String, Object?>{
      'locationServicesEnabled': true,
      'authorization': 'always',
      'accuracyAuthorization': 'full',
    },
    'lastAcceptedLocationAt': 1700000000000,
    'lastErrorCode': null,
    'lastErrorMessage': null,
    'wasRestoredAfterRelaunch': false,
    if (sample != null) ...<String, Object?>{
      'latestLocationSample': sample,
      'latestLocationSampleAction': 'received',
    },
  };
}

Map<String, Object?> _sample({
  required double latitude,
  required double longitude,
  required DateTime timestamp,
  required String context,
}) =>
    <String, Object?>{
      'latitude': latitude,
      'longitude': longitude,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'accuracy': 8.0,
      'context': context,
    };
