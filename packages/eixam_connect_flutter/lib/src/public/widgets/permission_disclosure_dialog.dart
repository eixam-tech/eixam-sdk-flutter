import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/material.dart';

Future<bool> showEixamPermissionDisclosureDialog({
  required BuildContext context,
  required EixamPermissionDisclosure disclosure,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      return EixamPermissionDisclosureDialog(disclosure: disclosure);
    },
  );
  return accepted ?? false;
}

class EixamPermissionDisclosureDialog extends StatelessWidget {
  const EixamPermissionDisclosureDialog({
    required this.disclosure,
    super.key,
  });

  final EixamPermissionDisclosure disclosure;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.policy_outlined),
      title: Text(disclosure.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(disclosure.body),
          if (disclosure.legalNote != null &&
              disclosure.legalNote!.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              disclosure.legalNote!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(disclosure.secondaryActionLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(disclosure.primaryActionLabel),
        ),
      ],
    );
  }
}
