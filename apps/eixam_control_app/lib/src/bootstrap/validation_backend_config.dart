enum ValidationBackendPreset {
  production,
  staging,
  customLocal,
  custom,
}

class ValidationBackendConfig {
  const ValidationBackendConfig({
    required this.preset,
    required this.label,
    required this.apiBaseUrl,
    required this.mqttWebsocketUrl,
  });

  final ValidationBackendPreset preset;
  final String label;
  final String apiBaseUrl;
  final String mqttWebsocketUrl;

  static const ValidationBackendConfig production = ValidationBackendConfig(
    preset: ValidationBackendPreset.production,
    label: 'Production',
    apiBaseUrl: 'https://api.eixam.io',
    mqttWebsocketUrl: 'wss://api.eixam.io/ws',
  );

  static const ValidationBackendConfig staging = ValidationBackendConfig(
    preset: ValidationBackendPreset.staging,
    label: 'Staging',
    apiBaseUrl: 'https://api.staging.eixam.io',
    mqttWebsocketUrl: 'wss://api.staging.eixam.io/ws',
  );

  static const ValidationBackendConfig customLocal = ValidationBackendConfig(
    preset: ValidationBackendPreset.customLocal,
    label: 'Custom local',
    apiBaseUrl: 'http://192.168.1.100:8080',
    mqttWebsocketUrl: 'ws://192.168.1.100:8080/ws',
  );

  static const List<ValidationBackendConfig> presets =
      <ValidationBackendConfig>[
    production,
    staging,
    customLocal,
  ];

  ValidationBackendConfig copyWith({
    ValidationBackendPreset? preset,
    String? label,
    String? apiBaseUrl,
    String? mqttWebsocketUrl,
  }) {
    return ValidationBackendConfig(
      preset: preset ?? this.preset,
      label: label ?? this.label,
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      mqttWebsocketUrl: mqttWebsocketUrl ?? this.mqttWebsocketUrl,
    );
  }

  Map<String, String> toPreferencesMap() {
    return <String, String>{
      'preset': preset.name,
      'label': label,
      'apiBaseUrl': apiBaseUrl,
      'mqttWebsocketUrl': mqttWebsocketUrl,
    };
  }

  factory ValidationBackendConfig.fromPreferencesMap(
    Map<String, String> values,
  ) {
    final presetName = values['preset'];
    final preset = ValidationBackendPreset.values.where(
      (candidate) => candidate.name == presetName,
    );
    return ValidationBackendConfig(
      preset: preset.isEmpty ? ValidationBackendPreset.custom : preset.first,
      label: values['label']?.trim().isNotEmpty == true
          ? values['label']!.trim()
          : 'Custom',
      apiBaseUrl: values['apiBaseUrl']?.trim() ?? production.apiBaseUrl,
      mqttWebsocketUrl:
          values['mqttWebsocketUrl']?.trim() ?? production.mqttWebsocketUrl,
    );
  }

  static ValidationBackendConfig presetFor(ValidationBackendPreset preset) {
    switch (preset) {
      case ValidationBackendPreset.production:
        return production;
      case ValidationBackendPreset.staging:
        return staging;
      case ValidationBackendPreset.customLocal:
        return customLocal;
      case ValidationBackendPreset.custom:
        return customLocal.copyWith(
          preset: ValidationBackendPreset.custom,
          label: 'Custom URL',
        );
    }
  }
}
