class SosTriggerPayload {
  const SosTriggerPayload({
    this.message,
    this.triggerSource = 'button_ui',
  });

  final String? message;
  final String triggerSource;
}
