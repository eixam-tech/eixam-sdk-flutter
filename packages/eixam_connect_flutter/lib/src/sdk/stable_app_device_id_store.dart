import 'dart:math';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/shared_prefs_sdk_store.dart';

class AppDeviceIdResolution {
  const AppDeviceIdResolution({
    required this.deviceId,
    required this.source,
    required this.persistenceScope,
    required this.limitation,
  });

  final String deviceId;
  final String source;
  final String persistenceScope;
  final String limitation;
}

class StableAppDeviceIdStore {
  StableAppDeviceIdStore({required SharedPrefsSdkStore localStore})
      : _localStore = localStore;

  final SharedPrefsSdkStore _localStore;

  Future<AppDeviceIdResolution> resolve({EixamSession? session}) async {
    final accountResolution = resolveFromSession(session);
    if (accountResolution != null) {
      return accountResolution;
    }
    return AppDeviceIdResolution(
      deviceId: await getOrCreate(),
      source: 'local_install_fallback',
      persistenceScope: 'local_install_only',
      limitation: 'lost_on_uninstall',
    );
  }

  Future<String> getOrCreate() async {
    final existing =
        await _localStore.readString(SharedPrefsSdkStore.appDeviceIdKey);
    final trimmed = existing?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
    final generated = 'app-device-local-${_randomHex(16)}';
    await _localStore.saveString(
      SharedPrefsSdkStore.appDeviceIdKey,
      generated,
    );
    return generated;
  }

  static AppDeviceIdResolution? resolveFromSession(EixamSession? session) {
    if (session == null) {
      return null;
    }
    final sdkUserId = _trimToNull(session.sdkUserId);
    if (sdkUserId != null) {
      return _accountResolution(
        value: sdkUserId,
        userHash: session.userHash,
      );
    }
    final canonicalExternalUserId =
        _trimToNull(session.canonicalExternalUserId);
    if (canonicalExternalUserId != null) {
      return _accountResolution(
        value: canonicalExternalUserId,
        userHash: session.userHash,
      );
    }
    final externalUserId = _trimToNull(session.externalUserId);
    if (externalUserId != null) {
      return _accountResolution(
        value: externalUserId,
        userHash: session.userHash,
      );
    }
    return null;
  }

  static AppDeviceIdResolution _accountResolution({
    required String value,
    required String userHash,
  }) {
    final isEmail = _looksLikeEmail(value);
    final tokenSource = isEmail ? _trimToNull(userHash) ?? value : value;
    return AppDeviceIdResolution(
      deviceId:
          'app-device-account-${_fnv1a64(tokenSource.trim().toLowerCase())}',
      source: isEmail ? 'email_hash' : 'account_hash',
      persistenceScope: 'account_stable',
      limitation: 'not_unique_across_multiple_mobile_devices_for_same_account',
    );
  }

  static String _randomHex(int bytes) {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String _fnv1a64(String value) {
    var hash = BigInt.parse('14695981039346656037');
    final prime = BigInt.parse('1099511628211');
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final unit in value.codeUnits) {
      hash ^= BigInt.from(unit);
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String? _trimToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static bool _looksLikeEmail(String value) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim());
  }
}
