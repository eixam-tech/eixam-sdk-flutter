import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_activity_availability_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_identity_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_location_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

const _backend = 'https://sdk.test';
const _identity = EixamSession.signed(
  appId: 'partner-app',
  externalUserId: 'user-a',
  userHash: 'signed-a',
  sdkUserId: 'sdk-a',
  canonicalExternalUserId: 'user-a',
);
final _appSnapshot = _identity.copyWith(
  sdkUserId: null,
  canonicalExternalUserId: null,
);
const _watchdog = Duration(seconds: 2);

void main() {
  test('production optional capability is local and safety isolated', () async {
    final h = _Harness(_Disk());
    try {
      await h.initialize();
      await h.sdk.setSession(_identity, deferRuntimeWork: true);
      final EixamConnectSdk facade = h.sdk;
      expect(facade, isA<ActivityRecordingControl>());
      final control = facade as ActivityRecordingControl;
      final session = await h.sdk.startActivitySession(
        activityKey: 'org.example.paddle',
      );
      final r = await control.startActivityRecording(activitySession: session);
      expect(
        (await control.getActiveActivityRecording())?.recordingId,
        r.recordingId,
      );
      expect(
        (await control.watchActiveActivityRecording().first)?.recordingId,
        r.recordingId,
      );
      expect(
        (await control
                .readActivityRecordingRoute(recordingId: r.recordingId)
                .single)
            .isLast,
        isTrue,
      );
      await expectLater(
        control.recoverActivityRecordingHistory(recordingId: r.recordingId),
        throwsA(isA<ActivityRecordingException>()),
      );
      await control.finishActivityRecording(recordingId: r.recordingId);
      expect(
        (await h.sdk.getActiveActivitySession())?.sessionId,
        session.sessionId,
      );
      expect(h.identityRequests, 0);
      expect(h.sdk.forbiddenCalls, isEmpty);
      expect(h.tracking.startCallCount, 0);
      expect(h.tracking.stopCallCount, 0);
      expect(h.sos.triggerCallCount, 0);
      expect(h.sos.cancelCallCount, 0);
      expect(h.sos.resolveCallCount, 0);
      expect(h.deathMan.activePlan, isNull);
      expect(h.deathMan.updateCallCount, 0);
    } finally {
      await h.dispose();
    }
  });

  for (final readiness in ['pending', 'offline', 'rotation']) {
    test(
      'production cold $readiness restores recording before remote readiness',
      () async {
        final disk = _Disk();
        final seed = _Harness(disk);
        late SdkActivityRecording original;
        await seed.initialize();
        await seed.sdk.setSession(_identity, deferRuntimeWork: true);
        final session = await seed.sdk.startActivitySession(
          activityKey: 'mountain',
        );
        original = await seed.sdk.startActivityRecording(
          activitySession: session,
        );
        await seed.dispose();
        final h = _Harness(disk);
        Future<EixamSession>? refresh;
        try {
          await h.initialize();
          h.offline = true;
          await h.sdk.setSession(
            _appSnapshot.copyWith(
              userHash: readiness == 'rotation' ? 'rotated' : 'signed-a',
            ),
            deferRuntimeWork: true,
          );
          if (readiness == 'pending') {
            h.offline = false;
            h.identityGate = Completer<http.Response>();
            refresh = h.sdk.refreshCanonicalIdentity();
            await pumpEventQueue();
          }
          final restored = await h.sdk.getActiveActivityRecording().timeout(
            _watchdog,
          );
          expect(restored?.recordingId, original.recordingId);
          expect(restored?.activitySessionId, original.activitySessionId);
          expect(restored?.recordingStartedAt, original.recordingStartedAt);
          expect(restored?.deviceIdentity, original.deviceIdentity);
          expect(restored?.routeRevision, original.routeRevision);
          expect(restored?.pointCount, 0);
          expect(h.identityRequests, readiness == 'pending' ? 1 : 0);
          if (readiness == 'offline') {
            await expectLater(
              h.sdk.refreshCanonicalIdentity(),
              throwsA(isA<NetworkException>()),
            );
            expect(
              (await h.sdk.getActiveActivityRecording())?.recordingId,
              original.recordingId,
            );
          }
        } finally {
          h.releaseIdentity();
          if (refresh != null) await refresh;
          await h.dispose();
        }
      },
    );
  }

  test('production canonical conflict purges and fences recorder', () async {
    final h = _Harness(_Disk());
    try {
      await h.initialize();
      await h.sdk.setSession(_identity, deferRuntimeWork: true);
      final r = await h.sdk.startActivityRecording(
        activitySession: await h.sdk.startActivitySession(
          activityKey: 'mountain',
        ),
      );
      h.canonicalId = 'conflicting';
      await expectLater(
        h.sdk.refreshCanonicalIdentity(),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        h.sdk.getActivityRecording(recordingId: r.recordingId),
        throwsA(isA<ActivityRecordingException>()),
      );
    } finally {
      await h.dispose();
    }
  });

  for (final stale in [false, true]) {
    test(
      'canonical binding ${stale ? 'rejects stale A assignment after switch to B' : 'accepts generation verified assignment only'}',
      () async {
        final registry = _GatedAssignmentRegistry();
        final h = _Harness(_Disk(), registry: registry);
        try {
          await h.initialize();
          await h.sdk.setSession(_identity, deferRuntimeWork: true);
          h.device.emitStatus(
            buildDeviceStatus(
              connected: false,
              nodeId: 42,
              canonicalHardwareId: 'AA:BB:CC:DD:EE:01',
            ),
          );
          await pumpEventQueue();
          final assignment = h.sdk.upsertRegisteredDevice(
            hardwareId: '42',
            firmwareVersion: '1',
            hardwareModel: 'TAG',
            pairedAt: DateTime.utc(2026),
          );
          await registry.entered.future;
          if (stale) {
            await h.sdk.setSession(
              _identity.copyWith(
                externalUserId: 'user-b',
                sdkUserId: 'sdk-b',
                canonicalExternalUserId: 'user-b',
              ),
              deferRuntimeWork: true,
            );
          }
          registry.release.complete();
          await assignment;
          final session = await h.sdk.startActivitySession(
            activityKey: 'mountain',
          );
          final r = await h.sdk.startActivityRecording(
            activitySession: session,
          );
          final binding = h.sdk.bindActivityRecordingDevice(
            recordingId: r.recordingId,
            deviceIdentity: 'AA:BB:CC:DD:EE:01',
          );
          if (stale) {
            await expectLater(
              binding,
              throwsA(
                isA<ActivityRecordingException>().having(
                  (e) => e.code,
                  'code',
                  'E_RECORDING_DEVICE_MISMATCH',
                ),
              ),
            );
            expect(
              (await h.sdk.getActiveActivityRecording())?.deviceIdentity,
              isNull,
            );
          } else {
            expect((await binding).deviceIdentity, 'AA:BB:CC:DD:EE:01');
          }
        } finally {
          if (!registry.release.isCompleted) registry.release.complete();
          await h.dispose();
        }
      },
    );
  }
}

class _Disk {
  _Disk({MemorySharedPrefsSdkStore? local})
    : local = local ?? MemorySharedPrefsSdkStore();
  final MemorySharedPrefsSdkStore local;
  final secure = InMemorySecureKeyValueStore();
}

class _Harness {
  _Harness(
    _Disk disk, {
    FakeSosRepository? sos,
    SdkDeviceRegistryRepository? registry,
  }) : sos = sos ?? FakeSosRepository() {
    client = MockClient((request) async {
      if (request.url.path == '/v1/sdk/me') {
        identityRequests++;
        if (identityGate case final gate?) return gate.future;
        if (offline) throw http.ClientException('offline', request.url);
        return identityResponse();
      }
      expect(request.url.path, '/v1/sdk/activities');
      if (availabilityGate case final gate?) return gate.future;
      if (offline) throw http.ClientException('offline', request.url);
      return http.Response(
        jsonEncode({
          'activities': [
            for (final key in keys)
              {'id': '2abf4d30-534c-48bf-acd2-fcb38a0a00ed', 'key': key},
          ],
        }),
        200,
      );
    });
    final context = SdkSessionContext();
    final transport = SdkHttpTransport(
      client: client,
      config: const EixamSdkConfig(apiBaseUrl: _backend),
      sessionContext: context,
    );
    sdk = _RecordingSpySdk(
      sosRepository: this.sos,
      trackingRepository: tracking,
      telemetryRepository: FakeTelemetryRepository(),
      contactsRepository: contacts,
      deviceRepository: device,
      deviceRegistryRepository: registry ?? FakeSdkDeviceRegistryRepository(),
      deathManRepository: deathMan,
      permissionsRepository: FakePermissionsRepository(),
      notificationsRepository: FakeNotificationsRepository(),
      realtimeClient: realtime,
      deviceSosController: DeviceSosController(),
      bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
      preferredBleDeviceStore: PreferredBleDeviceStore(localStore: disk.local),
      sessionStore: SdkSessionStore(
        localStore: disk.local,
        secureStore: disk.secure,
      ),
      sessionContext: context,
      localStore: disk.local,
      identityRemoteDataSource: HttpSdkIdentityRemoteDataSource(
        transport: transport,
      ),
      activityAvailabilityRemoteDataSource:
          HttpSdkActivityAvailabilityRemoteDataSource(transport: transport),
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
      backgroundLocationPlatformAdapter:
          UnsupportedBackgroundLocationPlatformAdapter(),
    );
  }
  final FakeSosRepository sos;
  final tracking = FakeTrackingRepository();
  final contacts = FakeContactsRepository();
  final device = FakeDeviceRepository(
    initialStatus: buildDeviceStatus(
      connected: false,
      paired: false,
      activated: false,
    ),
  );
  final deathMan = FakeDeathManRepository();
  final realtime = FakeRealtimeClient();
  late final MockClient client;
  late final _RecordingSpySdk sdk;
  bool offline = false;
  int identityStatus = 200;
  String canonicalId = 'sdk-a';
  int identityRequests = 0;
  List<String> keys = ['mountain'];
  Completer<http.Response>? identityGate;
  Completer<http.Response>? availabilityGate;
  http.Response identityResponse() => http.Response(
    jsonEncode({
      'user': {'id': canonicalId, 'external_user_id': 'user-a'},
    }),
    identityStatus,
  );
  void releaseIdentity() {
    final gate = identityGate;
    if (gate != null && !gate.isCompleted) gate.complete(identityResponse());
  }

  Future<void> initialize({String backend = _backend}) => sdk.initialize(
    EixamSdkConfig(apiBaseUrl: backend, deferRuntimeStartup: true),
  );
  Future<void> dispose() async {
    await sdk.dispose();
    await tracking.dispose();
    await contacts.dispose();
    await device.dispose();
    await deathMan.dispose();
    await realtime.dispose();
    await sos.dispose();
    client.close();
  }
}

class _RecordingSpySdk extends EixamConnectSdkImpl {
  _RecordingSpySdk({
    required super.sosRepository,
    required super.trackingRepository,
    required super.telemetryRepository,
    required super.contactsRepository,
    required super.deviceRepository,
    required super.deviceRegistryRepository,
    required super.deathManRepository,
    required super.permissionsRepository,
    required super.notificationsRepository,
    required super.realtimeClient,
    required super.deviceSosController,
    required super.bleIncomingEvents,
    required super.preferredBleDeviceStore,
    required super.sessionStore,
    required super.sessionContext,
    required super.localStore,
    required super.identityRemoteDataSource,
    required super.activityAvailabilityRemoteDataSource,
    required super.protectionPlatformAdapter,
    required super.backgroundTelemetryPlatformAdapter,
    required super.backgroundLocationPlatformAdapter,
  });
  final forbiddenCalls = <String>[];
  Never _forbidden(String name) {
    forbiddenCalls.add(name);
    throw StateError('Unexpected $name');
  }

  @override
  Stream<EixamDevicePositionBatch> watchDevicePositionBatches() =>
      _forbidden('position subscription');
  @override
  Future<DevicePositionBacklogSyncResult> syncDevicePositionBacklog({
    required DateTime since,
    DateTime? until,
    Duration timeout = const Duration(seconds: 5),
  }) => _forbidden('backlog');
  @override
  Future<DeviceReadyResult> ensureDeviceReady() => _forbidden('provisioning');
  @override
  Future<DeviceUnprovisionResult> unprovisionDevice() =>
      _forbidden('unprovisioning');
  @override
  Future<FirmwareUpdateSession> startFirmwareUpdate({
    required String deviceId,
    required String releaseId,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) => _forbidden('OTA');
  @override
  Future<EnterProtectionModeResult> enterProtectionMode({
    ProtectionModeOptions options = const ProtectionModeOptions(),
  }) => _forbidden('Protection acquire');
  @override
  Future<ProtectionStatus> exitProtectionMode() =>
      _forbidden('Protection release');
  @override
  Future<DeathManPlan> scheduleDeathMan({
    required DateTime expectedReturnAt,
    Duration gracePeriod = const Duration(minutes: 30),
    Duration checkInWindow = const Duration(minutes: 10),
    bool autoTriggerSos = true,
  }) => _forbidden('DMP enable');
  @override
  Future<void> cancelDeathMan(String planId) => _forbidden('DMP disable');
  @override
  Future<void> confirmDeathManCheckIn(String planId) =>
      _forbidden('DMP check-in');
}

class _GatedAssignmentRegistry extends FakeSdkDeviceRegistryRepository {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<BackendRegisteredDevice> upsertRegisteredDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  }) async {
    entered.complete();
    await release.future;
    return super.upsertRegisteredDevice(
      hardwareId: hardwareId,
      firmwareVersion: firmwareVersion,
      hardwareModel: hardwareModel,
      pairedAt: pairedAt,
    );
  }
}
