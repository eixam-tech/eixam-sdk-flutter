import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

/// Flutter-friendly controller for the Death Man Protocol workflow.
class DeathManController extends ChangeNotifier {
  DeathManController({required this.sdk});

  final EixamConnectSdk sdk;

  DeathManPlan? activePlan;
  String? lastError;
  Duration? timeRemaining;
  StreamSubscription<DeathManPlan>? _subscription;
  Timer? _ticker;

  DeathManStatus? get status => activePlan?.status;

  bool get hasActivePlan =>
      activePlan != null &&
      activePlan!.status != DeathManStatus.cancelled &&
      activePlan!.status != DeathManStatus.confirmedSafe &&
      activePlan!.status != DeathManStatus.expired;

  /// Loads the active plan, subscribes to updates and starts a local ticker.
  Future<void> initialize() async {
    activePlan = await sdk.getActiveDeathManPlan();
    _subscription ??= sdk.watchDeathManPlans().listen((plan) {
      activePlan = plan;
      _recalculate();
      notifyListeners();
    }, onError: (Object error) {
      lastError = error.toString();
      notifyListeners();
    });

    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _recalculate();
      notifyListeners();
    });

    _recalculate();
    notifyListeners();
  }

  /// Schedules a new Death Man plan.
  Future<void> schedule({
    required DateTime expectedReturnAt,
    Duration gracePeriod = const Duration(minutes: 30),
    Duration checkInWindow = const Duration(minutes: 10),
    bool autoTriggerSos = true,
  }) async {
    lastError = null;
    try {
      activePlan = await sdk.scheduleDeathMan(
        expectedReturnAt: expectedReturnAt,
        gracePeriod: gracePeriod,
        checkInWindow: checkInWindow,
        autoTriggerSos: autoTriggerSos,
      );
      _recalculate();
      notifyListeners();
    } on EixamSdkException catch (error) {
      lastError = error.message;
      notifyListeners();
    }
  }

  /// Confirms that the user is safe during the check-in window.
  Future<void> confirmCheckIn() async {
    final plan = activePlan;
    if (plan == null) return;
    lastError = null;
    try {
      await sdk.confirmDeathManCheckIn(plan.id);
    } on EixamSdkException catch (error) {
      lastError = error.message;
      notifyListeners();
    }
  }

  /// Cancels the active Death Man plan.
  Future<void> cancelPlan() async {
    final plan = activePlan;
    if (plan == null) return;
    lastError = null;
    try {
      await sdk.cancelDeathMan(plan.id);
    } on EixamSdkException catch (error) {
      lastError = error.message;
      notifyListeners();
    }
  }

  void _recalculate() {
    final plan = activePlan;
    if (plan == null) {
      timeRemaining = null;
      return;
    }

    final confirmationDeadline =
        plan.expectedReturnAt.add(plan.gracePeriod).add(plan.checkInWindow);

    switch (plan.status) {
      case DeathManStatus.scheduled:
      case DeathManStatus.monitoring:
        timeRemaining = plan.expectedReturnAt.difference(DateTime.now());
        break;
      case DeathManStatus.overdue:
      case DeathManStatus.awaitingConfirmation:
        timeRemaining = confirmationDeadline.difference(DateTime.now());
        break;
      default:
        timeRemaining = Duration.zero;
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _ticker?.cancel();
    super.dispose();
  }
}
