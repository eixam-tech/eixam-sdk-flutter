import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_availability_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_activity_availability_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/sdk/activity_availability_controller.dart';
import 'package:flutter_test/flutter_test.dart';

const a = EixamSession.signed(
  appId: 'app-a',
  externalUserId: 'user-a',
  userHash: 'signature',
);
const b = EixamSession.signed(
  appId: 'app-a',
  externalUserId: 'user-b',
  userHash: 'signature',
);
const mountain = SdkAvailableActivity(
  id: '6f1c2a3e-8b4d-4c1e-9f2a-1b3c4d5e6f70',
  key: 'mountain',
);
const ski = SdkAvailableActivity(
  id: '0a9b8c7d-6e5f-4a3b-8c2d-1e0f9a8b7c6d',
  key: '1__ski-',
);
final fetchedAt = DateTime.utc(2026, 10, 18, 10, 11, 12);

Future<void> bind(
  ActivityAvailabilityController controller,
  EixamSession? identity, {
  String backend = 'https://sdk.test',
  bool restore = true,
  bool clear = false,
}) => controller.withIdentityChange<void>(
  () async {},
  currentSession: () => identity,
  backend: () => backend,
  restoreExisting: restore,
  clearData: clear,
);

Matcher availabilityError(String suffix) => isA<ActivityAvailabilityException>()
    .having((e) => e.code, 'code', 'E_ACTIVITY_AVAILABILITY_$suffix');

final class Remote implements SdkActivityAvailabilityRemoteDataSource {
  int calls = 0;
  final sessions = <EixamSession>[];
  List<SdkAvailableActivity> activities = [mountain];
  Object? error;
  Completer<List<SdkAvailableActivity>>? next;

  @override
  Future<List<SdkAvailableActivity>> fetch(
    EixamSession session, {
    required String backend,
  }) async {
    calls++;
    sessions.add(session);
    final gate = next;
    next = null;
    if (gate != null) return gate.future;
    if (error != null) throw error!;
    return activities;
  }
}

final class MemoryStore implements ActivityAvailabilityStore {
  @override
  final Object writerNamespace = Object();
  String? raw;
  bool rejectWrites = false;
  bool throwWrites = false;
  bool applyBeforeFailure = false;
  bool rejectRemove = false;
  bool unreadable = false;
  bool failReadAfterWrite = false;
  Completer<void>? nextRead;
  Completer<void>? nextWrite;
  Completer<void>? nextRemove;
  int reads = 0;
  int writes = 0;
  int removes = 0;

  @override
  Future<String?> read() async {
    reads++;
    final gate = nextRead;
    nextRead = null;
    await gate?.future;
    if (unreadable) throw StateError('unreadable');
    return raw;
  }

  @override
  Future<bool> write(String value) async {
    writes++;
    final gate = nextWrite;
    nextWrite = null;
    await gate?.future;
    if ((!rejectWrites && !throwWrites) || applyBeforeFailure) raw = value;
    if (failReadAfterWrite) unreadable = true;
    if (throwWrites) throw StateError('write acknowledgement lost');
    return !rejectWrites;
  }

  @override
  Future<bool> remove() async {
    removes++;
    final gate = nextRemove;
    nextRemove = null;
    await gate?.future;
    if (rejectRemove) return false;
    raw = null;
    return true;
  }
}
