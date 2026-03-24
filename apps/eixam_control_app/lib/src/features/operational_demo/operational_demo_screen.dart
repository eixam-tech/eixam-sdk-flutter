import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/material.dart';

import 'guided_rescue_phase1_screen.dart';
import '../../shared/presentation/section_card.dart';
import 'operational_demo_sections.dart';

class OperationalDemoScreen extends StatefulWidget {
  const OperationalDemoScreen({
    super.key,
    required this.sdk,
    required this.onOpenTechnicalLab,
  });

  final EixamConnectSdk sdk;
  final VoidCallback onOpenTechnicalLab;

  @override
  State<OperationalDemoScreen> createState() => _OperationalDemoScreenState();
}

class _OperationalDemoScreenState extends State<OperationalDemoScreen> {
  late final SafetyOverviewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SafetyOverviewController(sdk: widget.sdk);
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Operational Demo')),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                RealtimeSummarySection(
                  connectionState: _controller.realtimeConnectionState,
                  lastEvent: _controller.lastRealtimeEvent,
                ),
                const SizedBox(height: 16),
                OperationalSosSection(
                  state: _controller.sosState ?? SosState.idle,
                  viewState: _controller.sosViewState,
                  incident: _controller.activeIncident,
                  loading: _controller.loadingSos,
                  onTrigger: _controller.triggerSos,
                  onCancel: _controller.cancelSos,
                ),
                const SizedBox(height: 16),
                TrackingSummarySection(
                  state: _controller.trackingState,
                  position: _controller.lastPosition,
                  loading: _controller.loadingTracking,
                  onStart: _controller.startTracking,
                  onStop: _controller.stopTracking,
                ),
                const SizedBox(height: 16),
                DeviceSummarySection(
                  viewState: _controller.deviceViewState,
                  onOpenTechnicalLab: widget.onOpenTechnicalLab,
                ),
                const SizedBox(height: 16),
                GuidedRescueEntrySection(
                  viewState: _controller.rescueViewState,
                  onOpen: _openGuidedRescue,
                ),
                const SizedBox(height: 16),
                DeathManSummarySection(
                  plan: _controller.activeDeathManPlan,
                  loading: _controller.loadingDeathMan,
                  onQuickDemo: _controller.scheduleQuickDeathMan,
                  onConfirm: _controller.confirmDeathMan,
                  onCancel: _controller.cancelDeathMan,
                ),
                const SizedBox(height: 16),
                ContactsSummarySection(
                  contacts: _controller.contacts,
                  loading: _controller.loadingContacts,
                  onAddSample: _controller.addSampleContact,
                  onToggleFirst: _controller.toggleFirstContact,
                  onRemoveFirst: _controller.removeFirstContact,
                ),
                if (_controller.lastError != null) ...[
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Last Error',
                    child: SelectableText(_controller.lastError!),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _openGuidedRescue() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GuidedRescuePhase1Screen(
          rescueViewState: _controller.rescueViewState,
          sosState: _controller.sosState ?? SosState.idle,
        ),
      ),
    );
  }
}
