import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../mappers/local_state_serializers.dart';
import '../datasources_remote/sos_remote_data_source.dart';
import '../datasources_local/shared_prefs_sdk_store.dart';
import '../../sdk/operational_realtime_client.dart';
import '../../sdk/sdk_mqtt_contract.dart';
import 'mqtt_sos_lifecycle_update.dart';

class MqttOperationalSosRepository implements SosRepository {
  MqttOperationalSosRepository({
    required this.realtimeClient,
    this.cancelRemoteDataSource,
    SharedPrefsSdkStore? localStore,
  }) : _localStore = localStore {
    _stateController.add(_stateMachine.current);
    _realtimeSub = realtimeClient.watchEvents().listen(_handleRealtimeEvent);
  }

  final OperationalRealtimeClient realtimeClient;
  final SosRemoteDataSource? cancelRemoteDataSource;
  final SharedPrefsSdkStore? _localStore;
  final SosStateMachine _stateMachine = SosStateMachine();
  final StreamController<SosState> _stateController =
      StreamController<SosState>.broadcast();

  StreamSubscription<RealtimeEvent>? _realtimeSub;
  SosIncident? _activeIncident;

  Future<void> restoreState() async {
    if (_localStore == null) {
      return;
    }

    final incidentJson =
        await _localStore.readJson(SharedPrefsSdkStore.sosIncidentKey);
    final stateRaw =
        await _localStore.readString(SharedPrefsSdkStore.sosStateKey);

    if (incidentJson != null) {
      _activeIncident = LocalStateSerializers.sosIncidentFromJson(incidentJson);
    }

    final restoredState = SosState.values.firstWhere(
      (value) => value.name == stateRaw,
      orElse: () => _activeIncident?.state ?? SosState.idle,
    );
    _restoreState(restoredState);
    _stateController.add(_stateMachine.current);
  }

  @override
  Future<SosIncident> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
  }) async {
    final current = _stateMachine.current;
    if (current != SosState.idle &&
        current != SosState.failed &&
        current != SosState.cancelled &&
        current != SosState.resolved) {
      throw const SosException(
        'E_SOS_ALREADY_ACTIVE',
        'There is already an SOS flow in progress',
      );
    }
    if (positionSnapshot == null) {
      throw const SosException(
        'E_SOS_POSITION_REQUIRED',
        'Operational SOS over MQTT requires a current location snapshot.',
      );
    }

    _emit(SosState.triggerRequested);
    _emit(SosState.triggeredLocal);
    _emit(SosState.sending);

    final incident = SosIncident(
      id: 'sos-${DateTime.now().microsecondsSinceEpoch}',
      state: SosState.sent,
      createdAt: DateTime.now().toUtc(),
      triggerSource: triggerSource,
      message: message,
      positionSnapshot: positionSnapshot,
    );

    try {
      await realtimeClient.publishOperationalSos(
        MqttOperationalSosRequest(
          timestamp: incident.createdAt,
          positionSnapshot: positionSnapshot,
        ),
      );
      _activeIncident = incident;
      _emit(SosState.sent);
      await _persistState();
      return incident;
    } catch (error) {
      _emit(SosState.failed);
      await _persistState();
      if (error is EixamSdkException) {
        rethrow;
      }
      throw SosException('E_SOS_TRIGGER_FAILED', error.toString());
    }
  }

  @override
  Future<SosIncident> cancelSos() async {
    final current = _stateMachine.current;
    if ({SosState.idle, SosState.cancelled, SosState.resolved}
            .contains(current) ||
        _activeIncident == null) {
      throw const SosException(
        'E_SOS_CANCEL_NOT_ALLOWED',
        'There is no active SOS to cancel',
      );
    }

    final remoteDataSource = cancelRemoteDataSource;
    if (remoteDataSource == null) {
      throw const SosException(
        'E_SOS_CANCEL_HTTP_UNAVAILABLE',
        'SOS cancellation requires an HTTP remote data source.',
      );
    }

    _activeIncident = _activeIncident!.copyWith(state: SosState.cancelRequested);
    _emit(SosState.cancelRequested);
    await _persistState();

    try {
      await remoteDataSource.cancelSos();
      await _persistState();
      return _activeIncident!;
    } catch (error) {
      _activeIncident = _activeIncident!.copyWith(state: SosState.sent);
      _emit(SosState.sent);
      await _persistState();
      if (error is EixamSdkException) {
        rethrow;
      }
      throw SosException('E_SOS_CANCEL_FAILED', error.toString());
    }
  }

  @override
  Future<SosState> getSosState() async => _stateMachine.current;

  @override
  Stream<SosState> watchSosState() => _stateController.stream;

  Future<void> dispose() async {
    await _realtimeSub?.cancel();
    await _stateController.close();
  }

  void _handleRealtimeEvent(RealtimeEvent event) {
    final update = MqttSosLifecycleUpdate.fromRealtimeEvent(event);
    if (update == null || _activeIncident == null) {
      return;
    }
    if (update.incidentId != _activeIncident!.id) {
      return;
    }

    _activeIncident = _activeIncident!.copyWith(state: update.state);
    _emit(update.state);
    unawaited(_persistState());
  }

  void _emit(SosState state) {
    _stateMachine.transitionTo(state);
    _stateController.add(_stateMachine.current);
  }

  void _restoreState(SosState state) {
    if (state == SosState.idle) {
      return;
    }

    final path = switch (state) {
      SosState.idle => const <SosState>[],
      SosState.arming => const <SosState>[SosState.arming],
      SosState.triggerRequested => const <SosState>[SosState.triggerRequested],
      SosState.triggeredLocal => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
        ],
      SosState.sending => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
        ],
      SosState.sent => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
          SosState.sent,
        ],
      SosState.acknowledged => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
          SosState.sent,
          SosState.acknowledged,
        ],
      SosState.cancelRequested => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
          SosState.sent,
          SosState.cancelRequested,
        ],
      SosState.cancelled => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
          SosState.sent,
          SosState.cancelRequested,
          SosState.cancelled,
        ],
      SosState.resolved => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
          SosState.sent,
          SosState.resolved,
        ],
      SosState.failed => const <SosState>[
          SosState.triggerRequested,
          SosState.failed,
        ],
    };

    for (final next in path) {
      _stateMachine.transitionTo(next);
    }
  }

  Future<void> _persistState() async {
    if (_localStore == null) {
      return;
    }

    await _localStore.saveString(
      SharedPrefsSdkStore.sosStateKey,
      _stateMachine.current.name,
    );
    if (_activeIncident == null || _stateMachine.current == SosState.idle) {
      await _localStore.remove(SharedPrefsSdkStore.sosIncidentKey);
      return;
    }

    await _localStore.saveJson(
      SharedPrefsSdkStore.sosIncidentKey,
      LocalStateSerializers.sosIncidentToJson(_activeIncident!),
    );
  }
}
