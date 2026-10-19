import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_database.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_store.dart';
import 'package:eixam_connect_flutter/src/sdk/activity_recording_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/activity_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'activity_test_support.dart' as logical;
import 'package:eixam_connect_flutter/src/sdk/device_position_backlog_coordinator.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_route_data.dart';

const recordingUserA = EixamSession.signed(
  appId: 'app',
  externalUserId: 'a',
  userHash: 'signed-a',
  sdkUserId: 'sdk-a',
  canonicalExternalUserId: 'a',
);
const recordingUserB = EixamSession.signed(
  appId: 'app',
  externalUserId: 'b',
  userHash: 'signed-b',
  sdkUserId: 'sdk-b',
  canonicalExternalUserId: 'b',
);
const tagA = 'AA:BB:CC:DD:EE:01';
const tagB = 'AA:BB:CC:DD:EE:02';

Matcher recordingError(String code) =>
    isA<ActivityRecordingException>().having((e) => e.code, 'code', code);

final class RecordingFixture {
  RecordingFixture._(
    this.directory,
    this.sessionStore,
    DatabaseFactory? factory,
    DevicePositionBacklogCoordinator? backlog,
  ) {
    sessions = ActivitySessionController(store: sessionStore, clock: () => now);
    database = ActivityRecordingDatabase(
      path: path,
      factory: factory ?? databaseFactoryFfiNoIsolate,
    );
    store = FaultRecordingStore(database);
    controller = ActivityRecordingController(
      store: store,
      sessionGuard: sessions.withCurrentActivitySession,
      verifyDevice: (identity) async {
        verifyCalls++;
        if (verifyGate case final gate?) await gate.future;
        return verified.contains(identity)
            ? ActivityRecordingDeviceEvidence(identity, connected: connected)
            : null;
      },
      clock: () => time?.call() ?? now,
      backlog: backlog,
      recoveryTimer: (duration, callback) =>
          recoveryTimer?.call(duration, callback) ?? Timer(duration, callback),
      historyEligible: (device) =>
          historyReady && connected && verified.contains(device),
    );
  }

  static Future<RecordingFixture> create({
    Directory? directory,
    logical.MemoryActivityStore? sessionStore,
    EixamSession? user = recordingUserA,
    DatabaseFactory? factory,
    DevicePositionBacklogCoordinator? backlog,
  }) async {
    final f = RecordingFixture._(
      directory ?? await Directory.systemTemp.createTemp('ar2a-'),
      sessionStore ?? logical.MemoryActivityStore(),
      factory,
      backlog,
    );
    await f.bind(user, restore: true);
    return f;
  }

  final Directory directory;
  final logical.MemoryActivityStore sessionStore;
  String get path => '${directory.path}/recordings.sqlite';
  late final ActivitySessionController sessions;
  late final ActivityRecordingDatabase database;
  late final FaultRecordingStore store;
  late final ActivityRecordingController controller;
  DateTime now = DateTime.utc(2026, 10, 19, 12);
  String backend = 'https://sdk.test';
  EixamSession? user;
  Set<String> verified = {tagA, tagB};
  bool connected = false;
  bool historyReady = false;
  DateTime Function()? time;
  Timer Function(Duration, void Function())? recoveryTimer;
  int verifyCalls = 0;
  Completer<void>? verifyGate;
  bool _disposed = false;

  Future<void> bind(
    EixamSession? next, {
    bool restore = false,
    bool clear = false,
    Future<void> Function()? action,
  }) {
    late Future<void> logicalWork;
    final work = controller.withIdentityChange<void>(
      () => logicalWork,
      currentSession: () => user,
      backend: () => backend,
      restoreExisting: restore,
      clearData: clear,
    );
    logicalWork = sessions.withIdentityChange<void>(
      () async {
        await action?.call();
        user = next;
      },
      currentSession: () => user,
      backend: () => backend,
      restoreExisting: restore,
      clearData: clear,
    );
    logicalWork.ignore();
    return work;
  }

  Future<SdkActivitySession> logicalStart([
    String key = 'org.example.paddling',
  ]) => sessions.startActivitySession(activityKey: key);
  Future<SdkActivityRecording> start({String? device}) async =>
      controller.startActivityRecording(
        activitySession: await logicalStart(),
        deviceIdentity: device,
      );
  Future<Database> raw() => databaseFactoryFfiNoIsolate.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await controller.dispose();
    await sessions.dispose();
  }

  Future<void> delete() async {
    await dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Faults wrap real SQL transactions, never simulate a recording database.
final class FaultRecordingStore implements ActivityRecordingStore {
  FaultRecordingStore(this.inner);
  final ActivityRecordingStore inner;
  bool failNextWrite = false;
  bool failClear = false;
  bool loseNextWriteAcknowledgement = false;
  ActivityRecordingPhase? failPhase;
  ActivityRecordingPhase? loseAcknowledgementPhase;
  Completer<void>? writeGate;
  Completer<void>? writeEntered;
  int committedWrites = 0;
  void Function(ActivityRecordingPhase)? onCommit;
  @override
  Object get writerNamespace => inner.writerNamespace;
  @override
  Future<T> transaction<T>(
    Future<T> Function(ActivityRecordingTransaction) action,
  ) async {
    var wrote = false;
    ActivityRecordingPhase? writtenPhase;
    final result = await inner.transaction((tx) async {
      final tracking = _WriteTrackingTransaction(tx);
      final result = await action(tracking);
      wrote = tracking.lastWrite != null;
      writtenPhase = tracking.lastWrite?.value.phase;
      if (wrote) {
        final gate = writeGate;
        writeGate = null;
        if (writeEntered case final entered?) {
          if (!entered.isCompleted) entered.complete();
        }
        await gate?.future;
        if (failNextWrite || failPhase == tracking.lastWrite?.value.phase) {
          failNextWrite = false;
          throw const ActivityRecordingException(
            'E_RECORDING_PERSISTENCE_FAILED',
            'Injected rollback.',
          );
        }
      }
      return result;
    });
    if (wrote) {
      committedWrites++;
      if (writtenPhase != null) onCommit?.call(writtenPhase!);
      if (loseNextWriteAcknowledgement ||
          loseAcknowledgementPhase == writtenPhase) {
        loseNextWriteAcknowledgement = false;
        loseAcknowledgementPhase = null;
        throw const ActivityRecordingException(
          'E_RECORDING_PERSISTENCE_FAILED',
          'Commit acknowledgement unavailable.',
        );
      }
    }
    return result;
  }

  @override
  Future<void> clear() async {
    if (failClear) {
      throw const ActivityRecordingException(
        'E_RECORDING_PERSISTENCE_FAILED',
        'Injected cleanup failure.',
      );
    }
    await inner.clear();
  }

  @override
  Future<void> dispose() => inner.dispose();
}

final class _WriteTrackingTransaction implements ActivityRecordingTransaction {
  _WriteTrackingTransaction(this.inner);
  final ActivityRecordingTransaction inner;
  ActivityRecordingRecord? lastWrite;
  @override
  Future<bool> reconcileOwner(ActivityRecordingOwner owner) =>
      inner.reconcileOwner(owner);
  @override
  Future<ActivityRecordingRecord?> active(String scope) => inner.active(scope);
  @override
  Future<ActivityRecordingRecord?> byId(String scope, String id) =>
      inner.byId(scope, id);
  @override
  Future<ActivityRecordingRecord?> forSession(String scope, String id) =>
      inner.forSession(scope, id);
  @override
  Future<void> insert(ActivityRecordingRecord record) async {
    await inner.insert(record);
    lastWrite = record;
  }

  @override
  Future<void> update(ActivityRecordingRecord record) async {
    await inner.update(record);
    lastWrite = record;
  }

  @override
  Future<ActivityRecordingRecord> finishRoute(
    ActivityRecordingRecord record,
    DateTime cutoff,
  ) async {
    final result = await inner.finishRoute(record, cutoff);
    lastWrite = result;
    return result;
  }

  @override
  Future<ActivityRecordingRecord> ingestRoute(
    ActivityRecordingRecord record,
    List<ActivityRecordingRouteEvidence> evidence,
  ) async {
    final updated = await inner.ingestRoute(record, evidence);
    if (updated.value.routeRevision != record.value.routeRevision) {
      lastWrite = updated;
    }
    return updated;
  }

  @override
  Future<ActivityRecordingRecord> inputPath(
    ActivityRecordingRecord record,
    bool connected,
    DateTime now,
  ) async {
    final result = await inner.inputPath(record, connected, now);
    lastWrite = result;
    return result;
  }

  @override
  Future<ActivityRecordingRecoveryWindow> recoveryWindow(
    ActivityRecordingRecord record,
  ) => inner.recoveryWindow(record);
  @override
  Future<void> needRecovery(ActivityRecordingRecord record) =>
      inner.needRecovery(record);
  @override
  Future<ActivityRecordingRecord> settleRecovery(
    ActivityRecordingRecord record, {
    required bool completed,
    DateTime? first,
    DateTime? last,
  }) async {
    final result = await inner.settleRecovery(
      record,
      completed: completed,
      first: first,
      last: last,
    );
    lastWrite = result;
    return result;
  }

  @override
  Future<ActivityRecordingRouteSlice> routePage(
    ActivityRecordingRecord record, {
    DateTime? fromInclusive,
    ActivityRecordingRouteCursor? after,
    required int pageSize,
  }) => inner.routePage(
    record,
    fromInclusive: fromInclusive,
    after: after,
    pageSize: pageSize,
  );

  @override
  Future<void> verifyEmptyRoute(String id) => inner.verifyEmptyRoute(id);
}
