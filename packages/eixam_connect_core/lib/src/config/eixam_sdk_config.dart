class EixamSdkConfig {
  const EixamSdkConfig({
    required this.apiBaseUrl,
    this.websocketUrl,
    this.enableLogging = false,
    this.deferRuntimeStartup = false,
    this.networkTimeout = const Duration(seconds: 15),
    this.defaultLocaleCode = 'es',
  });
  final String apiBaseUrl;
  final String? websocketUrl;
  final bool enableLogging;
  final bool deferRuntimeStartup;
  final Duration networkTimeout;
  final String defaultLocaleCode;
}
