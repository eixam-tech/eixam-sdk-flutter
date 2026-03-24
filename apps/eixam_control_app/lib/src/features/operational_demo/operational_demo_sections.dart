import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_ui/eixam_connect_ui.dart';
import 'package:flutter/material.dart';

import '../../shared/presentation/info_line.dart';
import '../../shared/presentation/section_card.dart';

class RealtimeSummarySection extends StatelessWidget {
  const RealtimeSummarySection({
    super.key,
    required this.connectionState,
    required this.lastEvent,
  });

  final RealtimeConnectionState? connectionState;
  final RealtimeEvent? lastEvent;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Realtime Summary',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Operational validation stays high-level here: monitor SDK state, trigger supported workflows, and jump to the Technical Lab for BLE internals.',
          ),
          const SizedBox(height: 12),
          InfoLine(
            label: 'Realtime connection',
            value: connectionState?.name ?? 'Unknown',
          ),
          InfoLine(
            label: 'Last realtime event',
            value: lastEvent?.type ?? '-',
          ),
          InfoLine(
            label: 'Last realtime timestamp',
            value: lastEvent?.timestamp.toIso8601String() ?? '-',
          ),
        ],
      ),
    );
  }
}

class OperationalSosSection extends StatelessWidget {
  const OperationalSosSection({
    super.key,
    required this.state,
    required this.viewState,
    required this.incident,
    required this.loading,
    required this.onTrigger,
    required this.onCancel,
  });

  final SosState state;
  final SosViewState viewState;
  final SosIncident? incident;
  final bool loading;
  final VoidCallback onTrigger;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'SOS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SosStatusBanner(state: state),
          const SizedBox(height: 16),
          Center(
            child: SosButtonRoundLarge(
              onPressed: viewState.canTrigger ? onTrigger : null,
              loading: loading,
              label: 'Trigger SOS',
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton(
              onPressed: viewState.canCancel ? onCancel : null,
              child: const Text('Cancel SOS'),
            ),
          ),
          const SizedBox(height: 12),
          InfoLine(label: 'State', value: viewState.label),
          InfoLine(label: 'Incident ID', value: incident?.id ?? '-'),
          InfoLine(label: 'Trigger source', value: incident?.triggerSource ?? '-'),
          InfoLine(label: 'Message', value: incident?.message ?? '-'),
        ],
      ),
    );
  }
}

class TrackingSummarySection extends StatelessWidget {
  const TrackingSummarySection({
    super.key,
    required this.state,
    required this.position,
    required this.loading,
    required this.onStart,
    required this.onStop,
  });

  final TrackingState? state;
  final TrackingPosition? position;
  final bool loading;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Tracking',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoLine(label: 'Tracking state', value: state?.name ?? 'Unknown'),
          InfoLine(label: 'Latitude', value: position?.latitude.toString() ?? '-'),
          InfoLine(
            label: 'Longitude',
            value: position?.longitude.toString() ?? '-',
          ),
          InfoLine(label: 'Accuracy', value: position?.accuracy.toString() ?? '-'),
          InfoLine(label: 'Source', value: position?.source.toString() ?? '-'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: loading ? null : onStart,
                child: const Text('Start tracking'),
              ),
              ElevatedButton(
                onPressed: loading ? null : onStop,
                child: const Text('Stop tracking'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class DeviceSummarySection extends StatelessWidget {
  const DeviceSummarySection({
    super.key,
    required this.viewState,
    required this.onOpenTechnicalLab,
  });

  final DeviceViewState viewState;
  final VoidCallback onOpenTechnicalLab;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Device Summary',
      onTap: onOpenTechnicalLab,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoLine(label: 'Status', value: viewState.statusLabel),
          InfoLine(label: 'Connection', value: viewState.connectionSummary),
          InfoLine(label: 'Readiness', value: viewState.readinessSummary),
          InfoLine(label: 'Battery', value: viewState.batterySummary),
          InfoLine(label: 'Model', value: viewState.modelLabel),
          InfoLine(label: 'Alias', value: viewState.aliasLabel),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: onOpenTechnicalLab,
            child: const Text('Open Technical Lab'),
          ),
        ],
      ),
    );
  }
}

class GuidedRescueEntrySection extends StatelessWidget {
  const GuidedRescueEntrySection({
    super.key,
    required this.viewState,
    required this.onOpen,
  });

  final RescueViewState viewState;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Guided Rescue Phase 1',
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(viewState.summary),
          const SizedBox(height: 12),
          InfoLine(label: 'Rescue session', value: viewState.sessionLabel),
          InfoLine(label: 'Target state', value: viewState.targetStateLabel),
          InfoLine(label: 'Device context', value: viewState.deviceLabel),
          InfoLine(
            label: 'Last known position',
            value: viewState.lastKnownPositionLabel,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: onOpen,
            child: const Text('Open Guided Rescue'),
          ),
        ],
      ),
    );
  }
}

class DeathManSummarySection extends StatelessWidget {
  const DeathManSummarySection({
    super.key,
    required this.plan,
    required this.loading,
    required this.onQuickDemo,
    required this.onConfirm,
    required this.onCancel,
  });

  final DeathManPlan? plan;
  final bool loading;
  final VoidCallback onQuickDemo;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Death Man Summary',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoLine(label: 'Plan ID', value: plan?.id ?? '-'),
          InfoLine(label: 'Status', value: plan?.status.toString() ?? '-'),
          InfoLine(
            label: 'Expected return',
            value: plan?.expectedReturnAt.toString() ?? '-',
          ),
          InfoLine(label: 'Grace period', value: plan?.gracePeriod.toString() ?? '-'),
          InfoLine(
            label: 'Check-in window',
            value: plan?.checkInWindow.toString() ?? '-',
          ),
          InfoLine(label: 'Auto SOS', value: plan?.autoTriggerSos.toString() ?? '-'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: loading ? null : onQuickDemo,
                child: const Text('Quick demo (20s)'),
              ),
              ElevatedButton(
                onPressed: loading || plan == null ? null : onConfirm,
                child: const Text('Confirm safe'),
              ),
              ElevatedButton(
                onPressed: loading || plan == null ? null : onCancel,
                child: const Text('Cancel plan'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ContactsSummarySection extends StatelessWidget {
  const ContactsSummarySection({
    super.key,
    required this.contacts,
    required this.loading,
    required this.onAddSample,
    required this.onToggleFirst,
    required this.onRemoveFirst,
  });

  final List<EmergencyContact> contacts;
  final bool loading;
  final VoidCallback onAddSample;
  final VoidCallback onToggleFirst;
  final VoidCallback onRemoveFirst;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Contacts Summary',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoLine(label: 'Total contacts', value: contacts.length.toString()),
          if (contacts.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...contacts.take(3).map(
                  (contact) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '${contact.name} - active=${contact.active} - priority=${contact.priority}',
                    ),
                  ),
                ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: loading ? null : onAddSample,
                child: const Text('Add sample'),
              ),
              ElevatedButton(
                onPressed: loading || contacts.isEmpty ? null : onToggleFirst,
                child: const Text('Toggle first'),
              ),
              ElevatedButton(
                onPressed: loading || contacts.isEmpty ? null : onRemoveFirst,
                child: const Text('Remove first'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
