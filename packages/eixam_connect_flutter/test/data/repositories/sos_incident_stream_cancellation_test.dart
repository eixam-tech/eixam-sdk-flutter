import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/repositories/api_sos_repository.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_sos_repository.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/mappers/local_state_serializers.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/mqtt_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

const _watchdog = Duration(seconds: 1);

void main() {
  for (final kind in ['mqtt', 'api', 'memory']) {
    group(kind, () {
      test('idle cancellation completes before cleanup', () async {
        final h = _Harness(kind);
        final values = <SosIncident?>[];
        final subscription = h.repository.watchCurrentIncident().listen(
          values.add,
        );
        try {
          await pumpEventQueue();
          expect(values, [null]);
          // Let the generator enter its idle wait; cancelling in the seed's
          // callback alone would miss the original await-for deadlock.
          await subscription.cancel().timeout(_watchdog);
          expect(h.realtime?.disconnects ?? 0, 0);
          expect(await h.repository.getCurrentIncident(), isNull);
        } finally {
          // Only cleanup after the completion assertion has passed or failed.
          await h.cleanup();
          await subscription.cancel();
        }
      });

      test(
        'active cancellation preserves incident, persistence and MQTT',
        () async {
          final h = _Harness(kind);
          await h.restore(_incident(SosState.sent));
          final before = await h.repository.getCurrentIncident();
          final persisted = Map.of(h.store.jsonValues);
          final values = <SosIncident?>[];
          final subscription = h.repository.watchCurrentIncident().listen(
            values.add,
          );
          try {
            await pumpEventQueue();
            expect(values.single, same(before));
            final remoteCalls = h.remote.calls;
            await subscription.cancel().timeout(_watchdog);
            expect(h.remote.calls, remoteCalls);
            expect(await h.repository.getCurrentIncident(), same(before));
            expect(await h.repository.getSosState(), SosState.sent);
            expect(h.store.jsonValues, persisted);
            expect(h.realtime?.publishes ?? 0, 0);
            expect(h.realtime?.disconnects ?? 0, 0);
            if (h.realtime != null) {
              expect(h.realtime!.events.hasListener, true);
            }
          } finally {
            await h.cleanup();
            await subscription.cancel();
          }
        },
      );

      test(
        'seed, duplicate updates and pause/resume retain their values',
        () async {
          final h = _Harness(kind);
          final values = <SosIncident?>[];
          final subscription = h.repository.watchCurrentIncident().listen(
            values.add,
          );
          try {
            await pumpEventQueue();
            await h.restore(_incident(SosState.sent));
            await pumpEventQueue();
            await h.restore(_incident(SosState.sent));
            await pumpEventQueue();
            expect(values.map((v) => v?.state), [
              null,
              SosState.sent,
              SosState.sent,
            ]);
            subscription.pause();
            await h.restore(_incident(SosState.acknowledged));
            await pumpEventQueue();
            expect(values, hasLength(3));
            subscription.resume();
            await pumpEventQueue();
            expect(values.last?.state, SosState.acknowledged);
            await subscription.cancel().timeout(_watchdog);
          } finally {
            await h.cleanup();
            await subscription.cancel();
          }
        },
      );

      test(
        'two observers remain independent across cancel and next update',
        () async {
          final h = _Harness(kind);
          final a = <SosIncident?>[];
          final b = <SosIncident?>[];
          final firstStream = h.repository.watchCurrentIncident();
          expect(firstStream.isBroadcast, false);
          final first = firstStream.listen(a.add);
          final second = h.repository.watchCurrentIncident().listen(b.add);
          try {
            await pumpEventQueue();
            await first.cancel().timeout(_watchdog);
            await h.restore(_incident(SosState.sent));
            await pumpEventQueue();
            expect(a, [null]);
            expect(b.map((v) => v?.state), [null, SosState.sent]);
            expect(h.realtime?.disconnects ?? 0, 0);
            await second.cancel().timeout(_watchdog);
          } finally {
            await h.cleanup();
            await first.cancel();
            await second.cancel();
          }
        },
      );

      test(
        'event concurrent with cancel cannot deliver after cancellation',
        () async {
          final h = _Harness(kind);
          final values = <SosIncident?>[];
          final subscription = h.repository.watchCurrentIncident().listen(
            values.add,
          );
          try {
            await pumpEventQueue();
            final update = h.restore(_incident(SosState.sent));
            final cancelling = subscription.cancel();
            await cancelling.timeout(_watchdog);
            final count = values.length;
            await update;
            await h.restore(_incident(SosState.acknowledged));
            await pumpEventQueue();
            expect(values, hasLength(count));
          } finally {
            await h.cleanup();
            await subscription.cancel();
          }
        },
      );
    });
  }

  test(
    'MQTT cancel and repository close can complete in either order',
    () async {
      for (final closeFirst in [false, true]) {
        final h = _Harness('mqtt');
        final subscription = h.repository.watchCurrentIncident().listen((_) {});
        await pumpEventQueue();
        final operations = closeFirst
            ? [h.cleanup(), subscription.cancel()]
            : [subscription.cancel(), h.cleanup()];
        await Future.wait(operations).timeout(_watchdog);
      }
    },
  );

  test('MQTT normal close completes an idle observer', () async {
    final h = _Harness('mqtt');
    final done = Completer<void>();
    final values = <SosIncident?>[];
    h.repository.watchCurrentIncident().listen(
      values.add,
      onDone: done.complete,
    );
    await pumpEventQueue();
    await h.cleanup().timeout(_watchdog);
    await done.future.timeout(_watchdog);
    expect(values, [null]);
  });

  test('MQTT observer survives cancel and real client reconnect', () async {
    const user = '1641f888-49aa-458f-9a32-ecbac516f44e';
    final transports = <_FakeMqttTransport>[];
    final client = MqttRealtimeClient(
      config: const EixamSdkConfig(
        apiBaseUrl: 'https://api.example.test',
        websocketUrl: 'wss://mqtt.example.test/mqtt',
      ),
      sessionContext: SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'test',
          externalUserId: user,
          sdkUserId: user,
          userHash: 'test',
        ),
      transportFactory: (_) {
        final transport = _FakeMqttTransport(failSubscription: () => false);
        transports.add(transport);
        return transport;
      },
      reconnectDelay: Duration.zero,
    );
    final repo = MqttOperationalSosRepository(realtimeClient: client);
    final a = <SosIncident?>[];
    final b = <SosIncident?>[];
    final cancelled = repo.watchCurrentIncident().listen(a.add);
    final remaining = repo.watchCurrentIncident().listen(b.add);
    try {
      await client.connect();
      final incident = await repo.triggerSos(triggerSource: 'button_ui');
      await pumpEventQueue();
      await client.disconnect();
      await cancelled.cancel().timeout(_watchdog);
      final cancelledCount = a.length;
      await client.connect();
      expect(transports, hasLength(2));
      expect(
        transports.last.operations.where((op) => op.startsWith('subscribe:')),
        isNotEmpty,
      );
      transports.last.emitMessage(
        topic: 'sos/events/$user',
        payload: jsonEncode({
          'type': 'sos_ack',
          'incidentId': incident.id,
          'status': 'active',
          'occurredAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      await pumpEventQueue();
      expect(b.last?.state, SosState.acknowledged);
      expect(a, hasLength(cancelledCount));
      expect(
        transports.last.operations.where((op) => op.startsWith('publish:')),
        isEmpty,
      );
      expect(transports.last.operations, isNot(contains('disconnect')));
      await remaining.cancel().timeout(_watchdog);
    } finally {
      await repo.dispose();
      await cancelled.cancel();
      await remaining.cancel();
      await client.dispose();
    }
  });
}

SosIncident _incident(SosState state) => SosIncident(
  id: 'incident-1',
  state: state,
  createdAt: DateTime.utc(2026, 1, 1),
  triggerSource: 'test',
);

class _Harness {
  _Harness(this.kind) {
    if (kind == 'mqtt') realtime = _Realtime();
    repository = switch (kind) {
      'mqtt' => MqttOperationalSosRepository(
        realtimeClient: realtime!,
        localStore: store,
      ),
      'api' => ApiSosRepository(remoteDataSource: remote, localStore: store),
      _ => InMemorySosRepository(localStore: store),
    };
  }

  final String kind;
  final store = MemorySharedPrefsSdkStore();
  final remote = _Remote();
  _Realtime? realtime;
  late final SosRepository repository;

  Future<void> restore(SosIncident incident) async {
    store.jsonValues[SharedPrefsSdkStore.sosIncidentKey] =
        LocalStateSerializers.sosIncidentToJson(incident);
    // The in-memory state machine restores its transition path only at startup.
    // Later idle restore notifications can replay the stored incident without
    // attempting to restart that already-active path.
    final memoryAlreadyActive =
        kind == 'memory' && await repository.getSosState() != SosState.idle;
    store.stringValues[SharedPrefsSdkStore.sosStateKey] = memoryAlreadyActive
        ? SosState.idle.name
        : incident.state.name;
    switch (repository) {
      case MqttOperationalSosRepository value:
        await value.restoreState();
      case ApiSosRepository value:
        await value.restoreState();
      case InMemorySosRepository value:
        await value.restoreState();
    }
  }

  Future<void> cleanup() async {
    switch (repository) {
      case MqttOperationalSosRepository value:
        await value.dispose();
        await realtime!.dispose();
      case ApiSosRepository value:
        await value.restoreState();
      case InMemorySosRepository value:
        store.stringValues[SharedPrefsSdkStore.sosStateKey] =
            SosState.idle.name;
        await value.restoreState();
    }
  }
}

class _Remote extends Fake implements SosRemoteDataSource {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    return super.noSuchMethod(invocation);
  }
}

class _Realtime extends Fake implements OperationalRealtimeClient {
  final events = StreamController<RealtimeEvent>.broadcast();
  int publishes = 0;
  int disconnects = 0;
  Future<void> dispose() => events.close();
  @override
  Stream<RealtimeEvent> watchEvents() => events.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {
    disconnects++;
  }

  @override
  Future<void> reconnectIfSessionChanged(EixamSession session) async {}
  @override
  Future<void> publishOperationalSos(MqttOperationalSosRequest request) async {
    publishes++;
  }
}

final class _FakeMqttTransport implements SdkMqttTransport {
  _FakeMqttTransport({required this.failSubscription});

  final bool Function() failSubscription;
  final StreamController<SdkMqttIncomingMessage> _messages =
      StreamController<SdkMqttIncomingMessage>.broadcast();
  final StreamController<SdkMqttDisconnectEvent> _disconnects =
      StreamController<SdkMqttDisconnectEvent>.broadcast();
  final List<String> operations = <String>[];

  @override
  Future<void> connect() async {
    operations.add('connect');
  }

  @override
  Future<void> disconnect() async {
    operations.add('disconnect');
  }

  @override
  Future<void> dispose() async {
    await _messages.close();
    await _disconnects.close();
  }

  @override
  Future<void> publish({
    required String topic,
    required String payload,
    SdkMqttQos qos = SdkMqttQos.atLeastOnce,
    bool retain = false,
  }) async {
    operations.add('publish:$topic');
  }

  @override
  Future<void> subscribe(String topic) async {
    operations.add('subscribe:$topic');
    if (failSubscription()) {
      throw StateError('synthetic subscription failure');
    }
  }

  @override
  Stream<SdkMqttDisconnectEvent> watchDisconnects() => _disconnects.stream;

  @override
  Stream<SdkMqttIncomingMessage> watchMessages() => _messages.stream;

  void emitMessage({required String topic, required String payload}) {
    _messages.add(SdkMqttIncomingMessage(topic: topic, payload: payload));
  }
}
