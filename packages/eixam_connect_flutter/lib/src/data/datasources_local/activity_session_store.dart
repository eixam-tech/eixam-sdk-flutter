import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'shared_prefs_sdk_store.dart';

/// Raw checked storage. The controller reconciles even thrown/rejected writes.
abstract interface class ActivitySessionStore {
  Object get writerNamespace;
  Future<String?> read();
  Future<bool> write(String value);
  Future<bool> remove();
}

final class SharedPrefsActivitySessionStore implements ActivitySessionStore {
  SharedPrefsActivitySessionStore(this.localStore);

  final SharedPrefsSdkStore localStore;

  @override
  Object get writerNamespace => localStore.storageNamespace;

  @override
  Future<String?> read() =>
      localStore.readFreshString(SharedPrefsSdkStore.activitySessionKey);

  @override
  Future<bool> write(String value) => localStore.writeStringChecked(
    SharedPrefsSdkStore.activitySessionKey,
    value,
  );

  @override
  Future<bool> remove() =>
      localStore.removeChecked(SharedPrefsSdkStore.activitySessionKey);
}

/// Private wire representation: one active record or the last ended tombstone.
final class ActivitySessionRecord {
  const ActivitySessionRecord({
    required this.ownerScope,
    required this.session,
    this.sdkUserId,
    this.endedAt,
  });

  factory ActivitySessionRecord.decode(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic> ||
        json['schemaVersion'] is! int ||
        json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported activity session schema.');
    }
    String string(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Invalid activity session $key.');
      }
      return value;
    }

    DateTime timestamp(String key) {
      final raw = string(key);
      final value = DateTime.parse(raw);
      if (!value.isUtc || value.toIso8601String() != raw) {
        throw FormatException('Invalid UTC activity $key.');
      }
      return value;
    }

    final key = string('activityKey');
    SdkActivitySession.validateActivityKey(key);
    final startedAt = timestamp('startedAt');
    final state = string('state');
    if (state != 'active' && state != 'ended') {
      throw const FormatException('Invalid activity lifecycle.');
    }
    final endedAt = state == 'ended' ? timestamp('endedAt') : null;
    if ((state == 'active' && json['endedAt'] != null) ||
        (endedAt != null && endedAt.isBefore(startedAt))) {
      throw const FormatException('Invalid activity timestamps.');
    }
    final sdkUserId = json['sdkUserId'];
    if (sdkUserId != null && (sdkUserId is! String || sdkUserId.isEmpty)) {
      throw const FormatException('Invalid SDK user identity.');
    }
    return ActivitySessionRecord(
      ownerScope: string('ownerScope'),
      sdkUserId: sdkUserId as String?,
      session: SdkActivitySession(
        sessionId: string('sessionId'),
        activityKey: key,
        startedAt: startedAt,
      ),
      endedAt: endedAt,
    );
  }

  final String ownerScope;
  final String? sdkUserId;
  final SdkActivitySession session;
  final DateTime? endedAt;

  SdkActivitySession? get active => endedAt == null ? session : null;

  String encode() => jsonEncode(<String, Object?>{
    'schemaVersion': 1,
    'ownerScope': ownerScope,
    'sdkUserId': sdkUserId,
    'sessionId': session.sessionId,
    'activityKey': session.activityKey,
    'startedAt': session.startedAt.toUtc().toIso8601String(),
    'state': endedAt == null ? 'active' : 'ended',
    'endedAt': endedAt?.toUtc().toIso8601String(),
  });
}
