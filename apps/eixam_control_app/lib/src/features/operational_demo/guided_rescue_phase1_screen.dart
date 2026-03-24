import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_ui/eixam_connect_ui.dart';
import 'package:flutter/material.dart';

import '../../shared/presentation/info_line.dart';
import '../../shared/presentation/section_card.dart';

class GuidedRescuePhase1Screen extends StatelessWidget {
  const GuidedRescuePhase1Screen({
    super.key,
    required this.rescueViewState,
    required this.sosState,
  });

  final RescueViewState rescueViewState;
  final SosState sosState;

  @override
  Widget build(BuildContext context) {
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
                  'This screen validates the host surface for Guided Rescue Phase 1. Rescue commands and rescue state must come from SDK APIs, so actions stay disabled until that contract exists.',
                ),
                const SizedBox(height: 12),
                SosStatusBanner(state: sosState),
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
                InfoLine(label: 'Rescue session', value: rescueViewState.sessionLabel),
                InfoLine(label: 'Target state', value: rescueViewState.targetStateLabel),
                InfoLine(label: 'Target device', value: rescueViewState.deviceLabel),
                InfoLine(
                  label: 'Last known position',
                  value: rescueViewState.lastKnownPositionLabel,
                ),
                InfoLine(
                  label: 'SDK availability',
                  value: rescueViewState.hasSdkSupport ? 'Ready' : 'Pending',
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
                  'Expected actions from the firmware handoff: request position, acknowledge SOS, buzzer on/off, and structured status request.',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: null,
                      child: const Text('Request position'),
                    ),
                    ElevatedButton(
                      onPressed: null,
                      child: const Text('Acknowledge SOS'),
                    ),
                    ElevatedButton(
                      onPressed: null,
                      child: const Text('Buzzer on'),
                    ),
                    ElevatedButton(
                      onPressed: null,
                      child: const Text('Buzzer off'),
                    ),
                    ElevatedButton(
                      onPressed: null,
                      child: const Text('Request status'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(rescueViewState.availabilityNote),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Missing SDK APIs',
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
                  'Belongs in SDK: rescue commands, STATUS_RESP decoding, rescue state transitions, target/victim models, and action availability.',
                ),
                SizedBox(height: 8),
                Text(
                  'Belongs in app: route into the rescue screen, render SDK state, and call rescue use cases once exposed.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
