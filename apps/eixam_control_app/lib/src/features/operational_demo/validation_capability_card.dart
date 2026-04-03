import 'package:flutter/material.dart';

import '../../shared/presentation/info_line.dart';
import '../../shared/presentation/section_card.dart';
import 'operational_demo_sections.dart';
import 'validation_models.dart';

class ValidationCapabilityCard extends StatelessWidget {
  const ValidationCapabilityCard({
    super.key,
    required this.viewModel,
    this.actions = const <Widget>[],
    this.child,
  });

  final ValidationCardViewModel viewModel;
  final List<Widget> actions;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final result = viewModel.result;
    return SectionCard(
      title: viewModel.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(viewModel.description)),
              const SizedBox(width: 12),
              _ValidationStatusBadge(status: result.status),
            ],
          ),
          if (viewModel.isCritical) ...[
            const SizedBox(height: 8),
            const Text(
              'Critical capability for MVP readiness.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 12),
          _TextBlock(
            label: 'Expected result',
            value: viewModel.expectation.expectedResult,
          ),
          const SizedBox(height: 8),
          _TextBlock(
            label: 'How to validate',
            value: viewModel.expectation.howToValidate,
          ),
          if (viewModel.currentState.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Current state',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ...viewModel.currentState.map(
              (field) => InfoLine(label: field.label, value: field.value),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Actions',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ],
          if (child != null) ...[
            const SizedBox(height: 12),
            child!,
          ],
          if ((result.diagnosticText ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            DiagnosticsBox(
              label: 'Diagnostics',
              value: result.diagnosticText!.trim(),
            ),
          ],
          if (result.lastExecutedAt != null) ...[
            const SizedBox(height: 12),
            InfoLine(
              label: 'Last execution',
              value: result.lastExecutedAt!.toLocal().toIso8601String(),
            ),
          ],
        ],
      ),
    );
  }
}

class _ValidationStatusBadge extends StatelessWidget {
  const _ValidationStatusBadge({required this.status});

  final ValidationRunStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = switch (status) {
      ValidationRunStatus.ok => (Colors.green.shade50, Colors.green.shade700),
      ValidationRunStatus.warning => (
          Colors.orange.shade50,
          Colors.orange.shade800,
        ),
      ValidationRunStatus.nok => (Colors.red.shade50, Colors.red.shade700),
      ValidationRunStatus.running => (
          Colors.blue.shade50,
          Colors.blue.shade700
        ),
      ValidationRunStatus.notRun => (
          Colors.grey.shade200,
          Colors.grey.shade800,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.$1,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.$2.withValues(alpha: 0.3)),
      ),
      child: Text(
        status.name.toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: colors.$2,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _TextBlock extends StatelessWidget {
  const _TextBlock({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(value),
      ],
    );
  }
}
