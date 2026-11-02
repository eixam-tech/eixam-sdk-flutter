import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/tag_alert_store.dart';
import 'package:eixam_connect_flutter/src/sdk/tag_alerts_controller.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/tag_alert_permission_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

const sessionA = EixamSession.signed(
  appId: 'app-a',
  externalUserId: 'user-a',
  userHash: 'signature',
);
const sessionB = EixamSession.signed(
  appId: 'app-a',
  externalUserId: 'user-b',
  userHash: 'signature',
);
const sessionOtherApp = EixamSession.signed(
  appId: 'app-b',
  externalUserId: 'user-a',
  userHash: 'signature',
);

Future<void> bind(
  TagAlertsController controller,
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

Matcher tagAlertsError(String suffix) => isA<TagAlertsException>().having(
  (e) => e.code,
  'code',
  'E_TAG_ALERTS_$suffix',
);

final class MemoryTagAlertStore implements TagAlertStore {
  @override
  final Object writerNamespace = Object();
  String? raw;
  bool rejectWrites = false;
  bool unreadable = false;
  Completer<void>? nextWrite;
  int writes = 0;
  int removes = 0;

  @override
  Future<String?> read() async {
    if (unreadable) throw StateError('unreadable');
    return raw;
  }

  @override
  Future<bool> write(String value) async {
    writes++;
    final gate = nextWrite;
    nextWrite = null;
    await gate?.future;
    if (!rejectWrites) raw = value;
    return !rejectWrites;
  }

  @override
  Future<bool> remove() async {
    removes++;
    raw = null;
    return true;
  }
}

final class RecordingTagAlertNotifier implements TagAlertNotifier {
  final List<String> calls = <String>[];
  final List<TagAlert> shown = <TagAlert>[];
  bool failCancelAll = false;
  bool failCancel = false;
  bool hangCancel = false;
  bool hangCancelAll = false;
  bool failShow = false;
  bool failCancelAllForDevice = false;

  @override
  Future<void> show(TagAlert alert) async {
    calls.add('show:${alert.deviceId}:${alert.kind.name}');
    shown.add(alert);
    if (failShow) throw StateError('show failed');
  }

  @override
  Future<void> schedule(TagAlert alert, DateTime at) async =>
      calls.add('schedule:${alert.deviceId}:${alert.kind.name}');

  @override
  Future<void> cancel(String deviceId, TagAlertKind kind) async {
    calls.add('cancel:$deviceId:${kind.name}');
    if (hangCancel) await Completer<void>().future;
    if (failCancel) throw StateError('cancel failed');
  }

  @override
  Future<void> cancelAllForDevice(String deviceId) async {
    calls.add('cancelAllForDevice:$deviceId');
    if (failCancelAllForDevice) throw StateError('cancelAllForDevice failed');
  }

  @override
  Future<void> cancelAll() async {
    calls.add('cancelAll');
    if (hangCancelAll) await Completer<void>().future;
    if (failCancelAll) throw StateError('cancelAll failed');
  }
}

final class CountingPermissionGateway implements TagAlertPermissionGateway {
  int stateCalls = 0;
  int requestCalls = 0;
  TagAlertPermissionState next = TagAlertPermissionState.notDetermined;

  @override
  Future<TagAlertPermissionState> state() async {
    stateCalls++;
    return next;
  }

  @override
  Future<TagAlertPermissionState> request() async {
    requestCalls++;
    return next = TagAlertPermissionState.granted;
  }
}
