import '../entities/death_man_plan.dart';
import '../enums/death_man_status.dart';

abstract class DeathManRepository {
  Future<DeathManPlan> scheduleDeathMan({
    required DateTime expectedReturnAt,
    required Duration gracePeriod,
    required Duration checkInWindow,
    required bool autoTriggerSos,
  });

  Future<DeathManPlan?> getActiveDeathManPlan();
  Future<void> confirmDeathManCheckIn(String planId);
  Future<void> cancelDeathMan(String planId);
  Future<DeathManPlan> updatePlanStatus(String planId, DeathManStatus status);
  Stream<DeathManPlan> watchDeathManPlans();
}
