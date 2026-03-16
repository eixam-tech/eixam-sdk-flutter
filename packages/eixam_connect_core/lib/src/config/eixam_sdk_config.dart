class EixamSdkConfig {
  final String apiBaseUrl;
  final String? websocketUrl;
  final bool enableLogging;
  final Duration networkTimeout;
  final String defaultLocaleCode;

  const EixamSdkConfig({
    required this.apiBaseUrl,
    this.websocketUrl,
    this.enableLogging = false,
    this.networkTimeout = const Duration(seconds: 15),
    this.defaultLocaleCode = 'es',
  });
}
