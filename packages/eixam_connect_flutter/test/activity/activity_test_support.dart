import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_session_store.dart';
import 'package:eixam_connect_flutter/src/sdk/activity_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

const userA = EixamSession.signed(
  appId: 'test-app',
  externalUserId: 'user-a',
  userHash: 'signed',
);
const userB = EixamSession.signed(
  appId: 'test-app',
  externalUserId: 'user-b',
  userHash: 'signed',
);

Future<void> bind(
  ActivitySessionController controller,
  EixamSession? identity, {
  bool restore = true,
  bool clear = false,
  String backend = 'https://sdk.test',
}) => controller.withIdentityChange<void>(
  () async {},
  currentSession: () => identity,
  backend: () => backend,
  restoreExisting: restore,
  clearData: clear,
);

Matcher activityError(String code) =>
    isA<ActivitySessionException>().having((e) => e.code, 'code', code);

final class MemoryActivityStore implements ActivitySessionStore {
  @override
  final Object writerNamespace = Object();
  String? raw;
  bool unreadable = false;
  bool rejectWrites = false;
  bool throwWrites = false;
  bool applyBeforeFailure = false;
  bool rejectRemove = false;
  bool failReadAfterWrite = false;
  Completer<void>? nextRead;
  Completer<void>? nextWrite;
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
    if (rejectRemove) return false;
    raw = null;
    return true;
  }
}
