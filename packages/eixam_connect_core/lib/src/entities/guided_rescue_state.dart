import '../enums/guided_rescue_action.dart';
import 'guided_rescue_status_snapshot.dart';
import 'tracking_position.dart';

class GuidedRescueState {
  const GuidedRescueState({
    required this.hasRuntimeSupport,
    required this.availableActions,
    this.targetNodeId,
    this.rescueNodeId,
    this.lastKnownTargetPosition,
    this.lastStatusSnapshot,
    this.unavailableReason,
    this.lastError,
    this.lastUpdatedAt,
  });

  const GuidedRescueState.unsupported({
    this.targetNodeId,
    this.rescueNodeId,
    this.lastKnownTargetPosition,
    this.lastStatusSnapshot,
    this.unavailableReason =
        'Guided Rescue Phase 1 is not implemented in the current SDK runtime yet.',
    this.lastError,
    this.lastUpdatedAt,
  })  : hasRuntimeSupport = false,
        availableActions = const <GuidedRescueAction>{};

  final bool hasRuntimeSupport;
  final Set<GuidedRescueAction> availableActions;
  final int? targetNodeId;
  final int? rescueNodeId;
  final TrackingPosition? lastKnownTargetPosition;
  final GuidedRescueStatusSnapshot? lastStatusSnapshot;
  final String? unavailableReason;
  final String? lastError;
  final DateTime? lastUpdatedAt;

  bool get hasSession => targetNodeId != null && rescueNodeId != null;

  bool canRun(GuidedRescueAction action) => availableActions.contains(action);

  GuidedRescueState copyWith({
    bool? hasRuntimeSupport,
    Set<GuidedRescueAction>? availableActions,
    int? targetNodeId,
    int? rescueNodeId,
    TrackingPosition? lastKnownTargetPosition,
    GuidedRescueStatusSnapshot? lastStatusSnapshot,
    String? unavailableReason,
    String? lastError,
    DateTime? lastUpdatedAt,
    bool clearLastError = false,
  }) {
    return GuidedRescueState(
      hasRuntimeSupport: hasRuntimeSupport ?? this.hasRuntimeSupport,
      availableActions: availableActions ?? this.availableActions,
      targetNodeId: targetNodeId ?? this.targetNodeId,
      rescueNodeId: rescueNodeId ?? this.rescueNodeId,
      lastKnownTargetPosition:
          lastKnownTargetPosition ?? this.lastKnownTargetPosition,
      lastStatusSnapshot: lastStatusSnapshot ?? this.lastStatusSnapshot,
      unavailableReason: unavailableReason ?? this.unavailableReason,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
    );
  }
}
