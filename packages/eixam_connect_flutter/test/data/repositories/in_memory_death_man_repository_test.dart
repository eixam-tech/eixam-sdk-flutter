import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  group('InMemoryDeathManRepository', () {
    test('schedules and updates the active plan', () async {
      final store = MemorySharedPrefsSdkStore();
      final repository = InMemoryDeathManRepository(localStore: store);

      final scheduled = await repository.scheduleDeathMan(
        expectedReturnAt: DateTime.utc(2026, 1, 1, 12),
        gracePeriod: const Duration(minutes: 30),
        checkInWindow: const Duration(minutes: 10),
        autoTriggerSos: true,
      );
      final overdue = await repository.updatePlanStatus(
        scheduled.id,
        DeathManStatus.overdue,
      );

      expect(scheduled.status, DeathManStatus.scheduled);
      expect(overdue.status, DeathManStatus.overdue);
      expect(
        store.jsonValues[SharedPrefsSdkStore.deathManPlanKey]?['status'],
        DeathManStatus.overdue.name,
      );
    });

    test('restores an existing plan from storage', () async {
      final store = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.deathManPlanKey] = <String, dynamic>{
          'id': 'deathman-1',
          'expectedReturnAt': DateTime.utc(2026, 1, 1, 12).toIso8601String(),
          'gracePeriodMs': const Duration(minutes: 30).inMilliseconds,
          'checkInWindowMs': const Duration(minutes: 10).inMilliseconds,
          'autoTriggerSos': true,
          'status': DeathManStatus.monitoring.name,
        };
      final repository = InMemoryDeathManRepository(localStore: store);

      await repository.restoreState();

      final restored = await repository.getActiveDeathManPlan();
      expect(restored, isNotNull);
      expect(restored!.status, DeathManStatus.monitoring);
    });

    test('confirm and cancel update the active plan state', () async {
      final repository = InMemoryDeathManRepository(
        localStore: MemorySharedPrefsSdkStore(),
      );
      final plan = await repository.scheduleDeathMan(
        expectedReturnAt: DateTime.utc(2026, 1, 1, 12),
        gracePeriod: const Duration(minutes: 30),
        checkInWindow: const Duration(minutes: 10),
        autoTriggerSos: true,
      );

      await repository.confirmDeathManCheckIn(plan.id);
      expect(
        (await repository.getActiveDeathManPlan())!.status,
        DeathManStatus.confirmedSafe,
      );

      await repository.cancelDeathMan(plan.id);
      expect(
        (await repository.getActiveDeathManPlan())!.status,
        DeathManStatus.cancelled,
      );
    });
  });
}
