import 'package:eixam_control_app/src/bootstrap/validation_backend_config.dart';
import 'package:eixam_control_app/src/bootstrap/validation_backend_config_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local debug preset uses the TCP MQTT default', () {
    expect(
      ValidationBackendConfig.customLocal.apiBaseUrl,
      'http://127.0.0.1:8080',
    );
    expect(
      ValidationBackendConfig.customLocal.mqttWebsocketUrl,
      'tcp://127.0.0.1:1883',
    );
    expect(ValidationLocalDebugDefaults.appId, 'app_localandroid01');
    expect(
      ValidationLocalDebugDefaults.externalUserId,
      'roger-android-local-01',
    );
    expect(
      ValidationLocalDebugDefaults.userHash,
      '8a59d9fce6ef5d541bbb7fe14d0ada32a0551f7a3152dbe9bb5a410b7ca58e9e',
    );
  });

  test('staging preset uses the validated TLS MQTT broker URI', () {
    expect(
      ValidationBackendConfig.staging.apiBaseUrl,
      'https://api.staging.eixam.io/',
    );
    expect(
      ValidationBackendConfig.staging.mqttWebsocketUrl,
      'ssl://mqtt.staging.eixam.io:8883',
    );
  });

  test('saved backend config wins over local first-run defaults', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'validation_backend_preset': ValidationBackendPreset.custom.name,
      'validation_backend_label': 'Saved custom',
      'validation_backend_api_base_url': 'http://10.0.2.2:8080',
      'validation_backend_mqtt_ws_url': 'ws://10.0.2.2:8080/ws',
    });

    final store = ValidationBackendConfigStore();
    final config = await store.load();

    expect(config.label, 'Saved custom');
    expect(config.apiBaseUrl, 'http://10.0.2.2:8080');
    expect(config.mqttWebsocketUrl, 'ws://10.0.2.2:8080/ws');
  });
}
