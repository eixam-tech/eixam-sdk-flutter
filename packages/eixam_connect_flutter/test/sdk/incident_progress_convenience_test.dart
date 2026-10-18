import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart' as public;
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

const _watchdog = Duration(seconds: 2);
const _secureChannel = MethodChannel(
  'dev.eixam.connect.flutter/secure_storage',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureValues = <String, String>{};
  var secureMutations = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureValues.clear();
    secureMutations = 0;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async {
          final args = Map<String, Object?>.from(call.arguments as Map);
          final key = args['key'] as String?;
          if (call.method != 'read') secureMutations++;
          switch (call.method) {
            case 'read':
              return secureValues[key];
            case 'write':
              secureValues[key!] = args['value'] as String;
              return null;
            case 'delete':
              secureValues.remove(key);
              return null;
            case 'deleteAll':
              secureValues.clear();
              return null;
          }
          throw StateError('Unexpected secure storage operation');
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'base-typed production SDK snapshot and idle convenience cancellation are observation only',
    () async {
      final EixamConnectSdk sdk = await _bootstrap();
      final beforeSecureMutations = secureMutations;
      final prefs = await SharedPreferences.getInstance();
      final beforePrefs = {
        for (final key in prefs.getKeys()) key: prefs.get(key),
      };
      final beforeDmp = await sdk.getActiveDeathManPlan();
      final values = <SosIncidentProgress?>[];
      final subscription = sdk.currentSosIncidentProgressStream.listen(
        values.add,
      );
      try {
        await pumpEventQueue();
        expect(values, [null]);
        expect(await sdk.getCurrentSosIncidentProgress(), isNull);
        await subscription.cancel().timeout(_watchdog);
        expect(await sdk.getTrackingState(), TrackingState.idle);
        expect(await sdk.getSosState(), SosState.idle);
        expect(await sdk.getCurrentSosIncident(), isNull);
        expect(await sdk.getActiveDeathManPlan(), beforeDmp);
        expect(secureMutations, beforeSecureMutations);
        expect({
          for (final key in prefs.getKeys()) key: prefs.get(key),
        }, beforePrefs);
      } finally {
        // This must not unblock cancellation until its assertion has resolved.
        await (sdk as dynamic).dispose();
        await subscription.cancel();
      }
    },
  );

  test(
    'base-typed production SDK closes convenience observation and restarts',
    () async {
      for (var run = 0; run < 2; run++) {
        final EixamConnectSdk sdk = await _bootstrap();
        final done = Completer<void>();
        final values = <SosIncidentProgress?>[];
        sdk.currentSosIncidentProgressStream.listen(
          values.add,
          onDone: done.complete,
        );
        await pumpEventQueue();
        expect(values, [null]);
        expect(await sdk.getTrackingState(), TrackingState.idle);
        await ((sdk as dynamic).dispose() as Future<void>).timeout(_watchdog);
        await done.future.timeout(_watchdog);
      }
    },
  );
  test(
    'base-typed active production provider performs zero domain or storage mutations',
    () async {
      final store = _ObservedStore();
      final secure = _ObservedSecureStore();
      final sos = _ObservedSosRepository();
      final realtime = _ObservedRealtime();
      final tracking = FakeTrackingRepository();
      final telemetry = FakeTelemetryRepository();
      final contacts = FakeContactsRepository();
      final devices = FakeDeviceRepository(initialStatus: buildDeviceStatus());
      final dmp = _ReadOnlyDmp();
      final implementation = EixamConnectSdkImpl(
        sosRepository: sos,
        trackingRepository: tracking,
        telemetryRepository: telemetry,
        contactsRepository: contacts,
        deviceRepository: devices,
        deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
        deathManRepository: dmp,
        permissionsRepository: FakePermissionsRepository(),
        notificationsRepository: FakeNotificationsRepository(),
        realtimeClient: realtime,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: PreferredBleDeviceStore(localStore: store),
        localStore: store,
        sosLifecycleSecureStore: secure,
      );
      final EixamConnectSdk sdk = implementation;
      final values = <SosIncidentProgress?>[];
      StreamSubscription<SosIncidentProgress?>? subscription;
      try {
        await pumpEventQueue();
        final beforeWrites = store.mutations;
        final beforeSecureWrites = secure.mutations;
        final beforeConnects = realtime.connectCallCount;
        final beforeDisconnects = realtime.disconnectCallCount;
        subscription = sdk.currentSosIncidentProgressStream.listen(values.add);
        final snapshot = await sdk.getCurrentSosIncidentProgress();
        await pumpEventQueue();
        expect(snapshot?.incidentId, sos.currentIncident.id);
        expect(values.single?.incidentId, sos.currentIncident.id);
        await subscription.cancel().timeout(_watchdog);
        expect(sos.triggerCallCount, 0);
        expect(sos.cancelCallCount, 0);
        expect(sos.resolveCallCount, 0);
        expect(realtime.publishedSos, isEmpty);
        expect(realtime.telemetryPublishes, 0);
        expect(realtime.connectCallCount, beforeConnects);
        expect(realtime.disconnectCallCount, beforeDisconnects);
        expect(telemetry.publishedPayloads, isEmpty);
        expect(tracking.startCallCount, 0);
        expect(tracking.stopCallCount, 0);
        expect(dmp.mutations, 0);
        expect(store.mutations, beforeWrites);
        expect(secure.mutations, beforeSecureWrites);
      } finally {
        await subscription?.cancel();
        await implementation.dispose();
        await sos.dispose();
        await tracking.dispose();
        await contacts.dispose();
        await devices.dispose();
        await realtime.dispose();
      }
    },
  );
}

Future<EixamConnectSdk> _bootstrap() => public.ApiSdkFactory.bootstrap(
  const EixamBootstrapConfig(
    appId: 'cancellation-test',
    environment: EixamEnvironment.sandbox,
    notificationPolicy: EixamNotificationPolicy.hostAppManaged,
    featureFlags: {'defer_runtime_startup': true},
    notificationTexts: EixamNotificationTexts(
      protectionActiveTitle: 'Test',
      protectionActiveBody: 'Test',
      protectionModeTitle: 'Test',
      protectionModeBody: 'Test',
      protectionModeChannelName: 'Test',
      protectionModeChannelDescription: 'Test',
      protectionSosChannelName: 'Test',
      protectionSosChannelDescription: 'Test',
      protectionPreSosTitle: 'Test',
      protectionPreSosBody: 'Test',
      protectionSosActiveTitle: 'Test',
      protectionSosActiveBody: 'Test',
      protectionSosResolvedTitle: 'Test',
      protectionSosResolvedBody: 'Test',
    ),
  ),
);

// A finite active snapshot fixture; idle cancellation uses the real factory/repository above.
class _ObservedSosRepository extends FakeSosRepository {
  _ObservedSosRepository() {
    currentIncident = SosIncident(
      id: 'observed-active',
      state: SosState.sent,
      createdAt: DateTime.utc(2026),
      isBackendConfirmed: true,
    );
  }
  @override
  Stream<SosIncident?> watchCurrentIncident() => Stream.value(currentIncident);
}

class _ObservedRealtime extends FakeRealtimeClient
    implements OperationalRealtimeClient {
  int telemetryPublishes = 0;
  @override
  Future<void> publishOperationalSos(MqttOperationalSosRequest request) async {
    publishedSos.add(request);
  }

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    telemetryPublishes++;
  }

  @override
  Future<void> reconnectIfSessionChanged(EixamSession session) async {}
}

class _ReadOnlyDmp extends Fake implements DeathManRepository {
  int mutations = 0;
  @override
  Future<DeathManPlan?> getActiveDeathManPlan() async => null;
  @override
  Stream<DeathManPlan> watchDeathManPlans() => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) {
    mutations++;
    throw StateError('Unexpected DMP mutation: ${invocation.memberName}');
  }
}

class _ObservedStore extends MemorySharedPrefsSdkStore {
  int mutations = 0;
  @override
  Future<void> saveJson(String key, Map<String, dynamic> value) async {
    mutations++;
    await super.saveJson(key, value);
  }

  @override
  Future<void> saveString(String key, String value) async {
    mutations++;
    await super.saveString(key, value);
  }

  @override
  Future<void> saveBool(String key, bool value) async {
    mutations++;
    await super.saveBool(key, value);
  }

  @override
  Future<void> remove(String key) async {
    mutations++;
    await super.remove(key);
  }
}

class _ObservedSecureStore implements SecureKeyValueStore {
  final inner = InMemorySecureKeyValueStore();
  int mutations = 0;
  @override
  Future<String?> read(String key) => inner.read(key);
  @override
  Future<bool> containsKey(String key) => inner.containsKey(key);
  @override
  Future<void> write(String key, String value) async {
    mutations++;
    await inner.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    mutations++;
    await inner.delete(key);
  }

  @override
  Future<void> deleteAll({String? namespace}) async {
    mutations++;
    await inner.deleteAll(namespace: namespace);
  }
}
