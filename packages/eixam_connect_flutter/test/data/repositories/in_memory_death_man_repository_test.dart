import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_death_man_repository.dart';
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

    test('does not expose terminal restored plans as active', () async {
      final store = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.deathManPlanKey] = <String, dynamic>{
          'id': 'deathman-1',
          'expectedReturnAt': DateTime.utc(2026, 1, 1, 12).toIso8601String(),
          'gracePeriodMs': const Duration(minutes: 30).inMilliseconds,
          'checkInWindowMs': const Duration(minutes: 10).inMilliseconds,
          'autoTriggerSos': true,
          'status': DeathManStatus.cancelled.name,
        };
      final repository = InMemoryDeathManRepository(localStore: store);

      await repository.restoreState();

      expect(await repository.getActiveDeathManPlan(), isNull);
      expect(
        store.jsonValues.containsKey(SharedPrefsSdkStore.deathManPlanKey),
        isFalse,
      );
    });

    test('confirm and cancel clear terminal plans from the active contract',
        () async {
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
      expect(await repository.getActiveDeathManPlan(), isNull);

      await repository.cancelDeathMan(plan.id);
      expect(await repository.getActiveDeathManPlan(), isNull);
    });

    test(
        'updatePlanStatus returns terminal states but no longer exposes them as active',
        () async {
      final store = MemorySharedPrefsSdkStore();
      final repository = InMemoryDeathManRepository(localStore: store);
      final plan = await repository.scheduleDeathMan(
        expectedReturnAt: DateTime.utc(2026, 1, 1, 12),
        gracePeriod: const Duration(minutes: 30),
        checkInWindow: const Duration(minutes: 10),
        autoTriggerSos: true,
      );

      final expired = await repository.updatePlanStatus(
        plan.id,
        DeathManStatus.expired,
      );

      expect(expired.status, DeathManStatus.expired);
      expect(await repository.getActiveDeathManPlan(), isNull);
      expect(
        store.jsonValues.containsKey(SharedPrefsSdkStore.deathManPlanKey),
        isFalse,
      );
    });
  });
}
