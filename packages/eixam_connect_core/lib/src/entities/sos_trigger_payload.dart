import 'os_sos_widget_activation.dart';

class SosTriggerPayload {
  const SosTriggerPayload({
    this.message,
    this.triggerSource = 'button_ui',
    this.osWidgetActivation,
  });

  static const String osWidgetSource = OsSosWidgetActivation.source;

  final String? message;
  final String triggerSource;
  final OsSosWidgetActivation? osWidgetActivation;
}
