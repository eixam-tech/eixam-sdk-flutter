import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/material.dart';

import '../../shared/presentation/section_card.dart';

class ConsoleSection extends StatelessWidget {
  const ConsoleSection({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SectionCard(title: title, child: child);
  }
}

class ValidationTextField extends StatelessWidget {
  const ValidationTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hintText,
    this.keyboardType,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String label;
  final String? hintText;
  final TextInputType? keyboardType;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class DiagnosticsBox extends StatelessWidget {
  const DiagnosticsBox({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          SelectableText(value),
        ],
      ),
    );
  }
}

class ContactListTile extends StatelessWidget {
  const ContactListTile({
    super.key,
    required this.contact,
    required this.onEdit,
    required this.onDelete,
  });

  final EmergencyContact contact;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(contact.name),
        subtitle: Text(
          'phone=${contact.phone}  email=${contact.email}  priority=${contact.priority}',
        ),
        trailing: Wrap(
          spacing: 8,
          children: [
            TextButton(onPressed: onEdit, child: const Text('Edit')),
            TextButton(onPressed: onDelete, child: const Text('Delete')),
          ],
        ),
      ),
    );
  }
}

class RegistryDeviceTile extends StatelessWidget {
  const RegistryDeviceTile({
    super.key,
    required this.device,
    required this.onUseAsDraft,
    required this.onDelete,
  });

  final BackendRegisteredDevice device;
  final VoidCallback onUseAsDraft;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text('${device.hardwareModel} (${device.hardwareId})'),
        subtitle: Text(
          'firmware=${device.firmwareVersion}\npairedAt=${device.pairedAt.toIso8601String()}',
        ),
        isThreeLine: true,
        trailing: Wrap(
          spacing: 8,
          children: [
            TextButton(onPressed: onUseAsDraft, child: const Text('Edit')),
            TextButton(onPressed: onDelete, child: const Text('Delete')),
          ],
        ),
      ),
    );
  }
}

String formatDateTime(DateTime? value) {
  if (value == null) {
    return '-';
  }
  final local = value.toLocal();
  final year = local.year.toString().padLeft(4, '0');
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final second = local.second.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute:$second';
}

String formatNullable(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? '-' : trimmed;
}
