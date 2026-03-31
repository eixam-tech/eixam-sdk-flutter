import 'package:shared_preferences/shared_preferences.dart';

import 'validation_backend_config.dart';

class ValidationBackendConfigStore {
  static const String _presetKey = 'validation_backend_preset';
  static const String _labelKey = 'validation_backend_label';
  static const String _apiBaseUrlKey = 'validation_backend_api_base_url';
  static const String _mqttWebsocketUrlKey = 'validation_backend_mqtt_ws_url';

  Future<ValidationBackendConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final apiBaseUrl = prefs.getString(_apiBaseUrlKey);
    final mqttWebsocketUrl = prefs.getString(_mqttWebsocketUrlKey);
    if (apiBaseUrl == null || mqttWebsocketUrl == null) {
      return ValidationBackendConfig.production;
    }

    return ValidationBackendConfig.fromPreferencesMap(<String, String>{
      'preset': prefs.getString(_presetKey) ?? '',
      'label': prefs.getString(_labelKey) ?? '',
      'apiBaseUrl': apiBaseUrl,
      'mqttWebsocketUrl': mqttWebsocketUrl,
    });
  }

  Future<void> save(ValidationBackendConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final values = config.toPreferencesMap();
    await prefs.setString(_presetKey, values['preset']!);
    await prefs.setString(_labelKey, values['label']!);
    await prefs.setString(_apiBaseUrlKey, values['apiBaseUrl']!);
    await prefs.setString(_mqttWebsocketUrlKey, values['mqttWebsocketUrl']!);
  }
}
