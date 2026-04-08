class EixamCustomEndpoints {
  const EixamCustomEndpoints({
    required this.apiBaseUrl,
    this.mqttUrl,
    this.websocketUrl,
  });

  final String apiBaseUrl;
  final String? mqttUrl;
  final String? websocketUrl;
}
