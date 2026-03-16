import 'package:flutter/material.dart';

import '../localization/eixam_ui_scope.dart';

class SosButtonRoundLarge extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool loading;
  final String? label;

  const SosButtonRoundLarge({
    super.key,
    required this.onPressed,
    this.loading = false,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final texts = EixamUiScope.textsOf(context);

    return SizedBox(
      width: 120,
      height: 120,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(shape: const CircleBorder()),
        onPressed: loading ? null : onPressed,
        child: loading
            ? const CircularProgressIndicator()
            : Text(label ?? texts.sosButtonLabel, textAlign: TextAlign.center),
      ),
    );
  }
}
