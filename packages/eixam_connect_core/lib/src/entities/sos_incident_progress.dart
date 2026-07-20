import '../enums/sos_delivery_channel.dart';
import '../enums/sos_actionability.dart';
import '../enums/sos_state.dart';
import 'sos_actuator_snapshot.dart';

enum SosProgressState {
  pending,
  inProgress,
  succeeded,
  partiallySucceeded,
  failed,
  unavailable,
  notApplicable,
  unknown,
}

enum SosProgressStepType {
  sosReceivedByEixam,
  emergencyContacts,
  eixamServices,
  emergencyResponseProvider,
  emergencyServices,
  partnerStation,
  incidentManagement,
  incidentResolved,
}

class SosProgressStep {
  const SosProgressStep({
    required this.type,
    required this.state,
    this.updatedAt,
    this.totalTargets,
    this.successfulTargets,
    this.failedTargets,
    this.detailCode,
  });

  final SosProgressStepType type;
  final SosProgressState state;
  final DateTime? updatedAt;
  final int? totalTargets;
  final int? successfulTargets;
  final int? failedTargets;
  final String? detailCode;
}

class SosIncidentProgress {
  const SosIncidentProgress({
    required this.incidentId,
    required this.steps,
    required this.lastUpdatedAt,
    required this.isTerminal,
    this.revision = 0,
    this.isUsingCachedData = false,
    this.provisionalIncidentId,
    this.canonicalIncidentId,
    this.preservedLocalOwnership = false,
    this.originKind = SosOriginKind.unknown,
    this.actionability = SosActionability.unknown,
    this.displaySurface = SosDisplaySurface.unknown,
  });

  factory SosIncidentProgress.fromEvidence({
    required String incidentId,
    required SosState incidentState,
    required DateTime createdAt,
    required SosDeliveryChannel? deliveryChannel,
    required SosActuatorSnapshot? actuators,
    required bool isBackendConfirmed,
    bool isUsingCachedData = false,
    String? provisionalIncidentId,
    String? canonicalIncidentId,
    bool preservedLocalOwnership = false,
    SosOriginKind originKind = SosOriginKind.unknown,
    SosActionability actionability = SosActionability.unknown,
    SosDisplaySurface displaySurface = SosDisplaySurface.unknown,
  }) {
    final steps = <SosProgressStep>[
      SosProgressStep(
        type: SosProgressStepType.sosReceivedByEixam,
        state: _receptionState(deliveryChannel, isBackendConfirmed),
        updatedAt: isBackendConfirmed ? createdAt : null,
        detailCode: isBackendConfirmed
            ? 'backend_incident_confirmed'
            : 'awaiting_backend_confirmation',
      ),
    ];

    final contacts = actuators?.items.where(
      (item) => item.type == SosActuatorType.emergencyContacts,
    );
    if (contacts != null && contacts.isNotEmpty) {
      steps.add(_contactsStep(contacts.first));
    }

    if (incidentState == SosState.acknowledged) {
      steps.add(
        SosProgressStep(
          type: SosProgressStepType.incidentManagement,
          state: SosProgressState.succeeded,
          updatedAt: _latestActuatorUpdate(actuators),
          detailCode: 'incident_acknowledged',
        ),
      );
    }
    if (incidentState == SosState.resolved ||
        incidentState == SosState.cancelled) {
      steps.add(
        SosProgressStep(
          type: SosProgressStepType.incidentResolved,
          state: SosProgressState.succeeded,
          updatedAt: _latestActuatorUpdate(actuators),
          detailCode: incidentState == SosState.cancelled
              ? 'incident_cancelled'
              : 'incident_resolved',
        ),
      );
    }

    return SosIncidentProgress(
      incidentId: incidentId,
      steps: List<SosProgressStep>.unmodifiable(steps),
      lastUpdatedAt: _latestActuatorUpdate(actuators) ?? createdAt,
      isTerminal: incidentState == SosState.resolved ||
          incidentState == SosState.cancelled,
      revision: actuators?.snapshotVersion ?? 0,
      isUsingCachedData: isUsingCachedData,
      provisionalIncidentId: provisionalIncidentId,
      canonicalIncidentId: canonicalIncidentId,
      preservedLocalOwnership: preservedLocalOwnership,
      originKind: originKind,
      actionability: actionability,
      displaySurface: displaySurface,
    );
  }

  final String incidentId;
  final List<SosProgressStep> steps;
  final DateTime lastUpdatedAt;
  final bool isTerminal;
  final int revision;
  final bool isUsingCachedData;
  final String? provisionalIncidentId;
  final String? canonicalIncidentId;
  final bool preservedLocalOwnership;
  final SosOriginKind originKind;
  final SosActionability actionability;
  final SosDisplaySurface displaySurface;
}

SosProgressState _receptionState(
  SosDeliveryChannel? deliveryChannel,
  bool isBackendConfirmed,
) {
  if (isBackendConfirmed) {
    return SosProgressState.succeeded;
  }
  if (deliveryChannel == SosDeliveryChannel.deviceOnly) {
    return SosProgressState.unavailable;
  }
  return SosProgressState.pending;
}

SosProgressStep _contactsStep(SosActuatorItem item) {
  if (item.status == SosActuatorStatus.skipped) {
    return SosProgressStep(
      type: SosProgressStepType.emergencyContacts,
      state: SosProgressState.notApplicable,
      updatedAt: item.updatedAt,
      totalTargets: item.contacts.length,
      detailCode: 'no_contact_targets',
    );
  }

  final contacts = _deduplicateContacts(item.contacts);
  final total = contacts.length;
  if (total == 0) {
    return SosProgressStep(
      type: SosProgressStepType.emergencyContacts,
      state: _itemStateWithoutTargets(item.status),
      updatedAt: item.updatedAt,
      detailCode: 'contact_counts_unavailable',
    );
  }

  final delivered = contacts
      .where((contact) => contact.status == SosActuatorStatus.delivered)
      .length;
  final failed = contacts
      .where((contact) => contact.status == SosActuatorStatus.failed)
      .length;
  final stillProcessing = contacts.any(
    (contact) =>
        contact.status == SosActuatorStatus.scheduled ||
        contact.status == SosActuatorStatus.sent,
  );
  final hasUnknown = contacts.any(
    (contact) => contact.status == SosActuatorStatus.unknown,
  );

  final state = switch ((delivered, failed, stillProcessing, hasUnknown)) {
    (final delivered, _, _, _) when delivered == total =>
      SosProgressState.succeeded,
    (_, final failed, false, _) when failed == total => SosProgressState.failed,
    (> 0, > 0, false, _) => SosProgressState.partiallySucceeded,
    (_, _, true, _) => SosProgressState.inProgress,
    (_, _, _, true) => SosProgressState.unknown,
    _ => SosProgressState.pending,
  };

  return SosProgressStep(
    type: SosProgressStepType.emergencyContacts,
    state: state,
    updatedAt: item.updatedAt,
    totalTargets: total,
    successfulTargets: delivered,
    failedTargets: failed,
    detailCode: stillProcessing ? 'contact_delivery_in_progress' : null,
  );
}

List<SosActuatorContact> _deduplicateContacts(
  List<SosActuatorContact> contacts,
) {
  final byContactId = <String, SosActuatorContact>{};
  final withoutStableId = <SosActuatorContact>[];
  for (final contact in contacts) {
    final id = contact.id?.trim();
    if (id == null || id.isEmpty) {
      withoutStableId.add(contact);
      continue;
    }
    final existing = byContactId[id];
    if (existing == null || _shouldReplaceContact(existing, contact)) {
      byContactId[id] = contact;
    }
  }
  return <SosActuatorContact>[...byContactId.values, ...withoutStableId];
}

bool _shouldReplaceContact(
  SosActuatorContact current,
  SosActuatorContact incoming,
) {
  final currentRank = _contactStatusRank(current.status);
  final incomingRank = _contactStatusRank(incoming.status);
  if (incomingRank != currentRank) {
    return incomingRank > currentRank;
  }
  final currentUpdatedAt = current.updatedAt;
  final incomingUpdatedAt = incoming.updatedAt;
  return incomingUpdatedAt != null &&
      (currentUpdatedAt == null || incomingUpdatedAt.isAfter(currentUpdatedAt));
}

int _contactStatusRank(SosActuatorStatus status) {
  return switch (status) {
    SosActuatorStatus.delivered => 5,
    SosActuatorStatus.sent => 4,
    SosActuatorStatus.scheduled => 3,
    SosActuatorStatus.failed => 2,
    SosActuatorStatus.skipped => 1,
    SosActuatorStatus.unknown => 0,
  };
}

SosProgressState _itemStateWithoutTargets(SosActuatorStatus status) {
  return switch (status) {
    SosActuatorStatus.scheduled => SosProgressState.inProgress,
    SosActuatorStatus.sent => SosProgressState.inProgress,
    SosActuatorStatus.delivered => SosProgressState.succeeded,
    SosActuatorStatus.failed => SosProgressState.failed,
    SosActuatorStatus.skipped => SosProgressState.notApplicable,
    SosActuatorStatus.unknown => SosProgressState.unknown,
  };
}

DateTime? _latestActuatorUpdate(SosActuatorSnapshot? snapshot) {
  DateTime? latest;
  for (final item in snapshot?.items ?? const <SosActuatorItem>[]) {
    final updatedAt = item.updatedAt;
    if (updatedAt != null && (latest == null || updatedAt.isAfter(latest))) {
      latest = updatedAt;
    }
  }
  return latest;
}
