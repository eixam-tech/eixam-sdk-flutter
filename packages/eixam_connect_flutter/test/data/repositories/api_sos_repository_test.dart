import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_history_dto.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_incident_dto.dart';
import 'package:eixam_connect_flutter/src/data/repositories/api_sos_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  group('ApiSosRepository', () {
    test('cancelSos clears current incident even if backend returns stale open',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      final store = MemorySharedPrefsSdkStore();
      final repository = ApiSosRepository(
        remoteDataSource: remoteDataSource,
        localStore: store,
      );

      await repository.triggerSos(triggerSource: 'button_ui');
      remoteDataSource.cancelResponseState = SosState.sent.name;

      final cancelled = await repository.cancelSos();

      expect(cancelled.state, SosState.cancelled);
      expect(await repository.getSosState(), SosState.idle);
      expect(await repository.getCurrentIncident(), isNull);
      expect(store.stringValues[SharedPrefsSdkStore.sosStateKey],
          SosState.idle.name);
      expect(store.jsonValues[SharedPrefsSdkStore.sosIncidentKey], isNull);
      expect(
        store.stringValues[SharedPrefsSdkStore.sosClosedIncidentKey],
        cancelled.id,
      );
    });

    test('restore keeps a locally closed incident from being rehydrated',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      final store = MemorySharedPrefsSdkStore();
      final first = ApiSosRepository(
        remoteDataSource: remoteDataSource,
        localStore: store,
      );

      final triggered = await first.triggerSos(triggerSource: 'button_ui');
      remoteDataSource.cancelResponseState = SosState.sent.name;
      await first.cancelSos();

      final restored = ApiSosRepository(
        remoteDataSource: remoteDataSource,
        localStore: store,
      );
      await restored.restoreState();

      expect(await restored.getSosState(), SosState.idle);
      expect(await restored.getCurrentIncident(), isNull);
      expect(
        store.stringValues[SharedPrefsSdkStore.sosClosedIncidentKey],
        triggered.id,
      );
    });
  });
}

final class _FakeSosRemoteDataSource implements SosRemoteDataSource {
  SosIncidentDto? active;
  String cancelResponseState = SosState.cancelled.name;

  @override
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? incidentId,
    String? cycleKey,
    OsSosWidgetActivation? osWidgetActivation,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  }) async {
    active = SosIncidentDto(
      id: incidentId ?? 'api-sos-1',
      state: SosState.sent.name,
      createdAt: DateTime.utc(2026, 1, 1, 10).toIso8601String(),
      triggerSource: triggerSource,
      message: message,
    );
    return active!;
  }

  @override
  Future<SosIncidentDto?> cancelSos({
    String? deviceId,
    String? source,
    String? triggerSource,
    String? relaySource,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayHardwareId,
    String? incidentId,
    String? cycleKey,
  }) async {
    return active?.copyWith(state: cancelResponseState);
  }

  @override
  Future<SosIncidentDto?> resolveSos() async {
    final resolved = active?.copyWith(state: SosState.resolved.name);
    active = resolved;
    return resolved;
  }

  @override
  Future<SosIncidentDto?> getActiveSos() async => active;

  @override
  Future<SosHistoryPageDto> listSosHistory(
      {String? cursor, int limit = 20}) async {
    return const SosHistoryPageDto(items: [], hasMore: false);
  }
}
