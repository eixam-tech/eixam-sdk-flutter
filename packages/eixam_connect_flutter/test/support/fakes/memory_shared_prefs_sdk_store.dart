import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';

class MemorySharedPrefsSdkStore extends SharedPrefsSdkStore {
  MemorySharedPrefsSdkStore();

  final Map<String, Map<String, dynamic>> jsonValues =
      <String, Map<String, dynamic>>{};
  final Map<String, String> stringValues = <String, String>{};
  final Map<String, bool> boolValues = <String, bool>{};

  @override
  Future<void> saveJson(String key, Map<String, dynamic> value) async {
    jsonValues[key] = Map<String, dynamic>.from(value);
  }

  @override
  Future<Map<String, dynamic>?> readJson(String key) async {
    final value = jsonValues[key];
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  @override
  Future<void> saveString(String key, String value) async {
    stringValues[key] = value;
  }

  @override
  Future<String?> readString(String key) async => stringValues[key];

  @override
  Future<void> saveBool(String key, bool value) async {
    boolValues[key] = value;
  }

  @override
  Future<bool?> readBool(String key) async => boolValues[key];

  @override
  Future<void> remove(String key) async {
    jsonValues.remove(key);
    stringValues.remove(key);
    boolValues.remove(key);
  }
}
