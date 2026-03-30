import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'shared_prefs_sdk_store.dart';

/// Persists the authenticated SDK identity/bootstrap state between launches.
class SdkSessionStore {
  SdkSessionStore({required SharedPrefsSdkStore localStore})
      : _localStore = localStore;

  final SharedPrefsSdkStore _localStore;

  Future<void> save(EixamSession session) {
    return _localStore.saveJson(
      SharedPrefsSdkStore.sdkSessionKey,
      session.toJson(),
    );
  }

  Future<EixamSession?> load() async {
    final json = await _localStore.readJson(SharedPrefsSdkStore.sdkSessionKey);
    if (json == null) return null;
    try {
      return EixamSession.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() {
    return _localStore.remove(SharedPrefsSdkStore.sdkSessionKey);
  }
}
