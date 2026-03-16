import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../datasources_local/shared_prefs_sdk_store.dart';
import '../../mappers/local_state_serializers.dart';

/// Starter implementation of the Death Man repository.
///
/// It keeps the active plan in memory but can also persist it locally so the
/// monitoring workflow can be restored when the host app is reopened.
class InMemoryDeathManRepository implements DeathManRepository {
  InMemoryDeathManRepository({SharedPrefsSdkStore? localStore}) : _localStore = localStore;

  final SharedPrefsSdkStore? _localStore;
  final StreamController<DeathManPlan> _controller = StreamController<DeathManPlan>.broadcast();
  DeathManPlan? _activePlan;

  /// Restores the active plan from local storage, if any.
  Future<void> restoreState() async {
    if (_localStore == null) return;
    final json = await _localStore.readJson(SharedPrefsSdkStore.deathManPlanKey);
    if (json == null) return;

    _activePlan = LocalStateSerializers.deathManPlanFromJson(json);
    _controller.add(_activePlan!);
  }

  @override
  Future<void> cancelDeathMan(String planId) async {
    if (_activePlan?.id == planId) {
      _activePlan = _activePlan?.copyWith(status: DeathManStatus.cancelled);
      _controller.add(_activePlan!);
      await _persistState();
    }
  }

  @override
  Future<void> confirmDeathManCheckIn(String planId) async {
    if (_activePlan?.id == planId) {
      _activePlan = _activePlan?.copyWith(status: DeathManStatus.confirmedSafe);
      _controller.add(_activePlan!);
      await _persistState();
    }
  }

  @override
  Future<DeathManPlan?> getActiveDeathManPlan() async => _activePlan;

  @override
  Future<DeathManPlan> scheduleDeathMan({
    required DateTime expectedReturnAt,
    required Duration gracePeriod,
    required Duration checkInWindow,
    required bool autoTriggerSos,
  }) async {
    _activePlan = DeathManPlan(
      id: 'deathman-${DateTime.now().millisecondsSinceEpoch}',
      expectedReturnAt: expectedReturnAt,
      gracePeriod: gracePeriod,
      checkInWindow: checkInWindow,
      autoTriggerSos: autoTriggerSos,
      status: DeathManStatus.scheduled,
    );
    _controller.add(_activePlan!);
    await _persistState();
    return _activePlan!;
  }

  @override
  Future<DeathManPlan> updatePlanStatus(String planId, DeathManStatus status) async {
    if (_activePlan?.id != planId || _activePlan == null) {
      throw const DeathManException('E_DEATH_MAN_PLAN_NOT_FOUND', 'Death Man plan not found');
    }
    _activePlan = _activePlan!.copyWith(status: status);
    _controller.add(_activePlan!);
    await _persistState();
    return _activePlan!;
  }

  @override
  Stream<DeathManPlan> watchDeathManPlans() => _controller.stream;

  Future<void> _persistState() async {
    if (_localStore == null) return;

    if (_activePlan == null) {
      await _localStore.remove(SharedPrefsSdkStore.deathManPlanKey);
      return;
    }

    await _localStore.saveJson(
      SharedPrefsSdkStore.deathManPlanKey,
      LocalStateSerializers.deathManPlanToJson(_activePlan!),
    );
  }
}
