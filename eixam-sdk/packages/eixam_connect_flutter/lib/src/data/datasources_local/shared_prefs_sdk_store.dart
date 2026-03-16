import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight key-value store used by the SDK to persist runtime state.
///
/// This implementation intentionally stays simple for the starter project.
/// It allows the SDK to restore critical state after the host app restarts,
/// which is specially important for SOS, tracking and Death Man flows.
class SharedPrefsSdkStore {
  SharedPrefsSdkStore({SharedPreferences? prefs}) : _prefs = prefs;

  static const String sosIncidentKey = 'eixam.sos.active_incident';
  static const String sosStateKey = 'eixam.sos.state';
  static const String trackingPositionKey = 'eixam.tracking.last_position';
  static const String trackingStateKey = 'eixam.tracking.state';
  static const String deathManPlanKey = 'eixam.death_man.active_plan';
  static const String emergencyContactsKey = 'eixam.contacts.list';
  static const String deviceStatusKey = 'eixam.device.status';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  /// Persists a JSON-serializable map under [key].
  Future<void> saveJson(String key, Map<String, dynamic> value) async {
    final prefs = await _instance;
    await prefs.setString(key, jsonEncode(value));
  }

  /// Loads a JSON map for [key] or returns `null` when absent or invalid.
  Future<Map<String, dynamic>?> readJson(String key) async {
    final prefs = await _instance;
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Persists a plain string value.
  Future<void> saveString(String key, String value) async {
    final prefs = await _instance;
    await prefs.setString(key, value);
  }

  /// Reads a plain string value.
  Future<String?> readString(String key) async {
    final prefs = await _instance;
    return prefs.getString(key);
  }

  /// Removes the stored value for [key].
  Future<void> remove(String key) async {
    final prefs = await _instance;
    await prefs.remove(key);
  }
}
