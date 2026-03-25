import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_ui/eixam_connect_ui.dart';
import 'package:flutter/material.dart';

import '../../shared/presentation/info_line.dart';
import '../../shared/presentation/section_card.dart';

class GuidedRescuePhase1Screen extends StatelessWidget {
  const GuidedRescuePhase1Screen({
    super.key,
    required this.controller,
  });

  final SafetyOverviewController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final rescueViewState = controller.rescueViewState;
        final rescueState = controller.guidedRescueState ??
            const GuidedRescueState.unsupported();
        final sosState = controller.sosState ?? SosState.idle;
        final snapshot = rescueState.lastStatusSnapshot;

        return Scaffold(
          appBar: AppBar(title: const Text('Guided Rescue Phase 1')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SectionCard(
                title: 'Operational Intent',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'This screen is a thin validation host over the SDK. It only renders Guided Rescue state and triggers SDK actions.',
                    ),
                    const SizedBox(height: 12),
                    SosStatusBanner(state: sosState),
                    if (controller.loadingGuidedRescue) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'Current Context',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InfoLine(label: 'SOS state', value: sosState.name),
                    InfoLine(
                      label: 'Runtime support',
                      value: rescueViewState.hasSdkSupport
                          ? 'Available'
                          : 'Unavailable',
                    ),
                    InfoLine(
                      label: 'Action readiness',
                      value: rescueState.availableActions.isEmpty
                          ? 'Waiting for session/device readiness'
                          : 'Ready for device-backed actions',
                    ),
                    InfoLine(
                      label: 'Rescue session',
                      value: rescueViewState.sessionLabel,
                    ),
                    InfoLine(
                      label: 'Target node',
                      value: _formatNodeId(rescueState.targetNodeId),
                    ),
                    InfoLine(
                      label: 'Rescue node',
                      value: _formatNodeId(rescueState.rescueNodeId),
                    ),
                    InfoLine(
                      label: 'Target state',
                      value: rescueViewState.targetStateLabel,
                    ),
                    InfoLine(
                      label: 'Target device',
                      value: rescueViewState.deviceLabel,
                    ),
                    InfoLine(
                      label: 'Last updated',
                      value:
                          rescueState.lastUpdatedAt?.toIso8601String() ?? '-',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'Last Status Snapshot',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InfoLine(
                      label: 'Snapshot state',
                      value: snapshot?.targetState.name ?? '-',
                    ),
                    InfoLine(
                      label: 'Battery',
                      value: snapshot?.batteryLevel?.label ?? '-',
                    ),
                    InfoLine(
                      label: 'GPS quality',
                      value: snapshot?.gpsQuality?.toString() ?? '-',
                    ),
                    InfoLine(
                      label: 'Retry count',
                      value: snapshot?.retryCount.toString() ?? '-',
                    ),
                    InfoLine(
                      label: 'Relay pending ACK',
                      value: snapshot == null
                          ? '-'
                          : (snapshot.relayPendingAck ? 'Yes' : 'No'),
                    ),
                    InfoLine(
                      label: 'Internet available',
                      value: snapshot == null
                          ? '-'
                          : (snapshot.internetAvailable ? 'Yes' : 'No'),
                    ),
                    InfoLine(
                      label: 'Received at',
                      value: snapshot?.receivedAt.toIso8601String() ?? '-',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'Last Known Target Position',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InfoLine(
                      label: 'Position',
                      value: rescueViewState.lastKnownPositionLabel,
                    ),
                    InfoLine(
                      label: 'Source',
                      value: rescueState.lastKnownTargetPosition?.source.name ??
                          '-',
                    ),
                    InfoLine(
                      label: 'Timestamp',
                      value: rescueState.lastKnownTargetPosition?.timestamp
                              .toIso8601String() ??
                          '-',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'Phase 1 Actions',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'These controls call the public SDK contract only. Availability comes from GuidedRescueState.',
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton(
                          onPressed: _resolveAction(
                            enabled: rescueState
                                .canRun(GuidedRescueAction.requestStatus),
                            busy: controller.loadingGuidedRescue,
                            action: controller.requestGuidedRescueStatus,
                          ),
                          child: const Text('Request status'),
                        ),
                        ElevatedButton(
                          onPressed: _resolveAction(
                            enabled: rescueState
                                .canRun(GuidedRescueAction.requestPosition),
                            busy: controller.loadingGuidedRescue,
                            action: controller.requestGuidedRescuePosition,
                          ),
                          child: const Text('Request position'),
                        ),
                        ElevatedButton(
                          onPressed: _resolveAction(
                            enabled: rescueState
                                .canRun(GuidedRescueAction.acknowledgeSos),
                            busy: controller.loadingGuidedRescue,
                            action: controller.acknowledgeGuidedRescueSos,
                          ),
                          child: const Text('Acknowledge SOS'),
                        ),
                        ElevatedButton(
                          onPressed: _resolveAction(
                            enabled:
                                rescueState.canRun(GuidedRescueAction.buzzerOn),
                            busy: controller.loadingGuidedRescue,
                            action: controller.enableGuidedRescueBuzzer,
                          ),
                          child: const Text('Buzzer on'),
                        ),
                        ElevatedButton(
                          onPressed: _resolveAction(
                            enabled: rescueState
                                .canRun(GuidedRescueAction.buzzerOff),
                            busy: controller.loadingGuidedRescue,
                            action: controller.disableGuidedRescueBuzzer,
                          ),
                          child: const Text('Buzzer off'),
                        ),
                        OutlinedButton(
                          onPressed: _resolveAction(
                            enabled: rescueState.hasSession,
                            busy: controller.loadingGuidedRescue,
                            action: controller.clearGuidedRescueSession,
                          ),
                          child: const Text('Clear session'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(rescueViewState.availabilityNote),
                    if (rescueState.lastError != null) ...[
                      const SizedBox(height: 8),
                      SelectableText(
                          'SDK rescue error: ${rescueState.lastError}'),
                    ],
                    if (controller.lastError != null) ...[
                      const SizedBox(height: 8),
                      SelectableText(
                          'Last controller error: ${controller.lastError}'),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'Pending SDK/Platform Gaps',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: rescueViewState.missingSdkApis
                      .map(
                        (item) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('- $item'),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'SDK Boundary',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Belongs in SDK: rescue commands, STATUS_RESP decoding, rescue state transitions, session semantics, and action availability.',
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Belongs in app: route into the rescue screen, render GuidedRescueState, and trigger SDK methods for validation.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  VoidCallback? _resolveAction({
    required bool enabled,
    required bool busy,
    required Future<void> Function() action,
  }) {
    if (!enabled || busy) {
      return null;
    }
    return () {
      action();
    };
  }

  String _formatNodeId(int? nodeId) {
    if (nodeId == null) {
      return '-';
    }
    return '0x${(nodeId & 0xFFFF).toRadixString(16).padLeft(4, '0')}';
  }
}
