import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../datasources_local/shared_prefs_sdk_store.dart';
import '../../mappers/local_state_serializers.dart';

/// Starter implementation of the Death Man repository.
///
/// It keeps the active plan in memory but can also persist it locally so the
/// monitoring workflow can be restored when the host app is reopened.
class InMemoryDeathManRepository implements DeathManRepository {
  InMemoryDeathManRepository({SharedPrefsSdkStore? localStore})
      : _localStore = localStore;

  static const Set<DeathManStatus> _activeStatuses = <DeathManStatus>{
    DeathManStatus.scheduled,
    DeathManStatus.monitoring,
    DeathManStatus.overdue,
    DeathManStatus.awaitingConfirmation,
  };

  final SharedPrefsSdkStore? _localStore;
  final StreamController<DeathManPlan> _controller =
      StreamController<DeathManPlan>.broadcast();
  DeathManPlan? _activePlan;

  /// Restores the active plan from local storage, if any.
  Future<void> restoreState() async {
    if (_localStore == null) return;
    final json =
        await _localStore.readJson(SharedPrefsSdkStore.deathManPlanKey);
    if (json == null) return;

    final restoredPlan = LocalStateSerializers.deathManPlanFromJson(json);
    if (_isActiveStatus(restoredPlan.status)) {
      _activePlan = restoredPlan;
      _controller.add(restoredPlan);
      return;
    }

    _activePlan = null;
    await _localStore.remove(SharedPrefsSdkStore.deathManPlanKey);
  }

  @override
  Future<void> cancelDeathMan(String planId) async {
    if (_activePlan?.id == planId) {
      final cancelledPlan =
          _activePlan!.copyWith(status: DeathManStatus.cancelled);
      _controller.add(cancelledPlan);
      _activePlan = null;
      await _persistState();
    }
  }

  @override
  Future<void> confirmDeathManCheckIn(String planId) async {
    if (_activePlan?.id == planId) {
      final confirmedPlan =
          _activePlan!.copyWith(status: DeathManStatus.confirmedSafe);
      _controller.add(confirmedPlan);
      _activePlan = null;
      await _persistState();
    }
  }

  @override
  Future<DeathManPlan?> getActiveDeathManPlan() async {
    final plan = _activePlan;
    if (plan == null || !_isActiveStatus(plan.status)) {
      return null;
    }
    return plan;
  }

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
  Future<DeathManPlan> updatePlanStatus(
      String planId, DeathManStatus status) async {
    if (_activePlan?.id != planId || _activePlan == null) {
      throw const DeathManException(
          'E_DEATH_MAN_PLAN_NOT_FOUND', 'Death Man plan not found');
    }
    final updatedPlan = _activePlan!.copyWith(status: status);
    _controller.add(updatedPlan);
    _activePlan = _isActiveStatus(status) ? updatedPlan : null;
    await _persistState();
    return updatedPlan;
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

  bool _isActiveStatus(DeathManStatus status) =>
      _activeStatuses.contains(status);
}
