import '../enums/death_man_status.dart';

class DeathManPlan {
  final String id;
  final DateTime expectedReturnAt;
  final Duration gracePeriod;
  final Duration checkInWindow;
  final bool autoTriggerSos;
  final DeathManStatus status;

  const DeathManPlan({
    required this.id,
    required this.expectedReturnAt,
    required this.gracePeriod,
    required this.checkInWindow,
    required this.autoTriggerSos,
    required this.status,
  });

  DeathManPlan copyWith({
    DateTime? expectedReturnAt,
    Duration? gracePeriod,
    Duration? checkInWindow,
    bool? autoTriggerSos,
    DeathManStatus? status,
  }) {
    return DeathManPlan(
      id: id,
      expectedReturnAt: expectedReturnAt ?? this.expectedReturnAt,
      gracePeriod: gracePeriod ?? this.gracePeriod,
      checkInWindow: checkInWindow ?? this.checkInWindow,
      autoTriggerSos: autoTriggerSos ?? this.autoTriggerSos,
      status: status ?? this.status,
    );
  }
}
