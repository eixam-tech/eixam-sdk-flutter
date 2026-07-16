import 'package:flutter/widgets.dart';

import 'eixam_ui_texts.dart';

class EixamUiScope extends InheritedWidget {
  const EixamUiScope({
    super.key,
    required super.child,
    this.localeCode = 'es',
    this.overrides,
  });
  final String localeCode;
  final EixamUiTexts? overrides;

  static EixamUiTexts textsOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<EixamUiScope>();
    final localeCode = scope?.localeCode ?? 'es';
    final base = EixamUiTexts.fromLocaleCode(localeCode);
    final overrides = scope?.overrides;
    if (overrides == null) {
      return base;
    }

    return base.copyWith(
      sosButtonLabel: overrides.sosButtonLabel,
      sosIdle: overrides.sosIdle,
      sosSending: overrides.sosSending,
      sosSent: overrides.sosSent,
      sosCancelled: overrides.sosCancelled,
      sosFailed: overrides.sosFailed,
      sosUnknownPrefix: overrides.sosUnknownPrefix,
      deathManCheckInTitle: overrides.deathManCheckInTitle,
      deathManCheckInMessage: overrides.deathManCheckInMessage,
      confirmSafety: overrides.confirmSafety,
      deviceRegionTitle: overrides.deviceRegionTitle,
      deviceRegionPrompt: overrides.deviceRegionPrompt,
      deviceRegionConfirm: overrides.deviceRegionConfirm,
      deviceRegionCancel: overrides.deviceRegionCancel,
      deviceRegionApplying: overrides.deviceRegionApplying,
      deviceRegionSuccess: overrides.deviceRegionSuccess,
      deviceRegionError: overrides.deviceRegionError,
      deviceRegionDismiss: overrides.deviceRegionDismiss,
    );
  }

  @override
  bool updateShouldNotify(EixamUiScope oldWidget) {
    return localeCode != oldWidget.localeCode ||
        overrides != oldWidget.overrides;
  }
}
