import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../activity_availability_parser.dart';
import 'shared_prefs_sdk_store.dart';

/// Checked raw IO; serialized writes are reconciled by the controller.
abstract interface class ActivityAvailabilityStore {
  Object get writerNamespace;
  Future<String?> read();
  Future<bool> write(String value);
  Future<bool> remove();
}

final class SharedPrefsActivityAvailabilityStore
    implements ActivityAvailabilityStore {
  SharedPrefsActivityAvailabilityStore(this.localStore);

  final SharedPrefsSdkStore localStore;

  @override
  Object get writerNamespace => localStore.storageNamespace;
  @override
  Future<String?> read() =>
      localStore.readFreshString(SharedPrefsSdkStore.activityAvailabilityKey);
  @override
  Future<bool> write(String value) => localStore.writeStringChecked(
    SharedPrefsSdkStore.activityAvailabilityKey,
    value,
  );
  @override
  Future<bool> remove() =>
      localStore.removeChecked(SharedPrefsSdkStore.activityAvailabilityKey);
}

final class ActivityAvailabilityRecord {
  const ActivityAvailabilityRecord({
    required this.ownerScope,
    required this.snapshot,
    this.sdkUserId,
  });

  factory ActivityAvailabilityRecord.decode(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic> ||
        json['schemaVersion'] is! int ||
        json['schemaVersion'] != 1 ||
        json['ownerScope'] is! String ||
        (json['ownerScope'] as String).isEmpty ||
        json['fetchedAt'] is! String) {
      throw const FormatException('Unsupported availability cache envelope.');
    }
    final fetchedAt = DateTime.parse(json['fetchedAt'] as String);
    final sdkUserId = json['sdkUserId'];
    if (!fetchedAt.isUtc ||
        fetchedAt.toIso8601String() != json['fetchedAt'] ||
        (sdkUserId != null &&
            (sdkUserId is! String || sdkUserId.trim().isEmpty))) {
      throw const FormatException('Invalid availability cache metadata.');
    }
    return ActivityAvailabilityRecord(
      ownerScope: json['ownerScope'] as String,
      sdkUserId: sdkUserId as String?,
      snapshot: SdkActivityAvailability(
        activities: parseAvailableActivities(json),
        fetchedAt: fetchedAt,
        fromCache: true,
      ),
    );
  }

  final String ownerScope;
  final String? sdkUserId;
  final SdkActivityAvailability snapshot;

  String encode() => jsonEncode({
    'schemaVersion': 1,
    'ownerScope': ownerScope,
    'sdkUserId': sdkUserId,
    'fetchedAt': snapshot.fetchedAt.toUtc().toIso8601String(),
    'activities': [
      for (final activity in snapshot.activities)
        {'id': activity.id, 'key': activity.key},
    ],
  });
}
