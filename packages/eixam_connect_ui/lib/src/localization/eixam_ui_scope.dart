import 'package:flutter/widgets.dart';

import 'eixam_ui_texts.dart';

class EixamUiScope extends InheritedWidget {
  final String localeCode;
  final EixamUiTexts? overrides;

  const EixamUiScope({
    super.key,
    required super.child,
    this.localeCode = 'es',
    this.overrides,
  });

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
    );
  }

  @override
  bool updateShouldNotify(EixamUiScope oldWidget) {
    return localeCode != oldWidget.localeCode || overrides != oldWidget.overrides;
  }
}
