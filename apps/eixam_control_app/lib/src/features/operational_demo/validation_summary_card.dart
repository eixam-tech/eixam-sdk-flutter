import 'package:flutter/material.dart';

import '../../shared/presentation/info_line.dart';
import '../../shared/presentation/section_card.dart';
import 'validation_models.dart';

class ValidationSummaryCard extends StatelessWidget {
  const ValidationSummaryCard({
    super.key,
    required this.summary,
  });

  final ValidationSummaryViewModel summary;

  @override
  Widget build(BuildContext context) {
    final readiness = switch (summary.readiness) {
      ValidationReadiness.ready => ('READY', Colors.green),
      ValidationReadiness.partial => ('PARTIAL', Colors.orange),
      ValidationReadiness.blocked => ('BLOCKED', Colors.red),
    };

    return SectionCard(
      title: 'Global Summary',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Operational validation readiness',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: readiness.$2.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: readiness.$2.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  readiness.$1,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: readiness.$2.shade700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          InfoLine(
            label: 'Total capabilities',
            value: summary.totalCapabilities.toString(),
          ),
          InfoLine(label: 'Passed', value: summary.passed.toString()),
          InfoLine(label: 'Warnings', value: summary.warning.toString()),
          InfoLine(label: 'Failed', value: summary.failed.toString()),
          InfoLine(label: 'Running', value: summary.running.toString()),
          InfoLine(label: 'Not run', value: summary.notRun.toString()),
        ],
      ),
    );
  }
}
