import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/material.dart';

import '../localization/eixam_ui_scope.dart';

class SosStatusBanner extends StatelessWidget {

  const SosStatusBanner({super.key, required this.state});
  final SosState state;

  @override
  Widget build(BuildContext context) {
    final texts = EixamUiScope.textsOf(context);
    final label = texts.labelForSosState(state);

    return Material(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        child: Text(label),
      ),
    );
  }
}
