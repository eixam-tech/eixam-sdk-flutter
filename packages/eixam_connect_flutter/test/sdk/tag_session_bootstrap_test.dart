import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/tag_radio_repair_ledger.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/tag_volume_store.dart';
import 'package:eixam_connect_flutter/src/diagnostics/sdk_release_log.dart';
import 'package:eixam_connect_flutter/src/provisioning/provisioning_command_result.dart';
import 'package:eixam_connect_flutter/src/provisioning/strict_device_provisioning_config.dart';
import 'package:eixam_connect_flutter/src/sdk/tag_session_bootstrap.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Test fixture shaped like a provisioned EU868 TAG on the Eixam plan
// (LORA_RELAY_FINDINGS_1.0.6.md, TAG A after re-provisioning).
const _config = StrictDeviceProvisioningConfig(
  regionCode: 3,
  region: 'EU868',
  tel: ProvisioningTelConfig(
    frequencyKhz: 866500,
    bandwidthKhz: 250,
    spreadingFactor: 9,
    codingRateDenominator: 5,
    txPowerDbm: 14,
  ),
  sos: ProvisioningSosConfig(
    frequencyHz: 869618000,
    bandwidthHz: 62500,
    spreadingFactor: 7,
    codingRateDenominator: 5,
    txPowerDbm: 27,
    preambleSymbols: 16,
  ),
);

const Duration _quiet = TagSessionBootstrap.defaultQuietWindow;

DeviceRuntimeStatus _status({
  bool provisioned = true,
  bool usePreset = false,
  bool txEnabled = true,
  int sf = 9,
  int region = 3,
  List<int> rawBytes = const <int>[],
}) => DeviceRuntimeStatus(
  region: region,
  modemPreset: 0,
  meshSpreadingFactor: sf,
  isProvisioned: provisioned,
  usePreset: usePreset,
  txEnabled: txEnabled,
  inetOk: false,
  positionConfirmed: false,
  nodeId: 0x27d447db,
  batteryPercent: 80,
  telIntervalSeconds: 45,
  rawBytes: rawBytes,
);

/// Doc 36 §9 `0x23` v3 reply: 3 B header + the 11 B of v2 + episode fields.
List<int> _v3Reply({
  int activeCycle = 0,
  required int sosState,
  List<int> pending = const <int>[],
}) {
  List<int> u32(int v) => <int>[
    v & 0xFF,
    (v >> 8) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 24) & 0xFF,
  ];
  return <int>[
    0xE9, 0x78, 0x03, //
    3, 0, 9, 0x05, 0xdb, 0x47, 0xd4, 0x27, 80, 45, 0, // v2 fields
    ...u32(activeCycle),
    sosState,
    pending.length,
    for (final cycle in pending) ...u32(cycle),
  ];
}

/// The Meshtastic default slot some field TAGs run: LONG_FAST, SF11.
DeviceRuntimeStatus _longFast() => _status(usePreset: true, sf: 11);

/// A fake TAG: answers 0x23, records every write, and applies a saved radio
/// config only when it reboots (like firmware's 0x20 + 0x22).
final class _FakeTag {
  _FakeTag(this.status);

  DeviceRuntimeStatus status;
  final List<String> writes = <String>[];
  ProvisioningCommandOutcome radioOutcome = ProvisioningCommandOutcome.ok;
  Object? radioError;
  bool appliesOnReboot = true;
  bool _savedGoodRadio = false;
  int statusReads = 0;

  Future<DeviceRuntimeStatus> read() async {
    statusReads++;
    writes.add('0x23');
    return status;
  }

  Future<ProvisioningCommandOutcome> ack(int opcode, List<int> bytes) async {
    writes.add('0x${opcode.toRadixString(16)}');
    if (opcode == 0x20) {
      expect(bytes, encodeFullRadioConfig(_config));
      final error = radioError;
      if (error != null) throw error;
      if (radioOutcome == ProvisioningCommandOutcome.ok) _savedGoodRadio = true;
      return radioOutcome;
    }
    expect(opcode, 0x21);
    expect(bytes, encodeSosRadioConfig(_config));
    return ProvisioningCommandOutcome.ok;
  }

  Future<void> reboot() async {
    writes.add('0x22');
    if (appliesOnReboot && (_savedGoodRadio || !status.usePreset)) {
      status = _status();
    }
  }
}

final class _MemoryVolumeStore implements TagVolumeStore {
  final Map<String, TagVolumes> values = <String, TagVolumes>{};

  @override
  Future<TagVolumes?> read(Iterable<String> deviceKeys) async {
    for (final key in deviceKeys) {
      final value = values[key];
      if (value != null) return value;
    }
    return null;
  }

  @override
  Future<void> write(
    Iterable<String> deviceKeys, {
    int? notification,
    int? sos,
  }) async {
    for (final key in deviceKeys) {
      values[key] = TagVolumes(notification: notification, sos: sos);
    }
  }
}

final class _Env {
  _Env(DeviceRuntimeStatus status, {this.storedVolume = 10})
    : tag = _FakeTag(status);

  final _FakeTag tag;
  final int? storedVolume;
  final _MemoryVolumeStore volumes = _MemoryVolumeStore();
  final List<TagSessionBootstrapEvent> events = <TagSessionBootstrapEvent>[];
  String? sosHold;
  String? radioHold;
  DateTime? lastSosFrameAt;
  bool linkUp = true;
  bool configAvailable = true;
  int configFetches = 0;
  StrictDeviceProvisioningConfig config = _config;
  TagRadioRepairLedger ledger = InMemoryTagRadioRepairLedger();

  late TagSessionBootstrap bootstrap;

  TagSessionBootstrap build(FakeAsync async) {
    final volume = storedVolume;
    if (volume != null) {
      volumes.values['hw-1'] = TagVolumes(notification: volume, sos: volume);
    }
    final clock = async.getClock(DateTime.utc(2026, 11, 19, 12));
    bootstrap = TagSessionBootstrap(
      readStatus: tag.read,
      sosHold: () async => sosHold,
      radioWriteHold: () async => radioHold,
      lastSosFrameAt: () => lastSosFrameAt,
      volumeStore: volumes,
      sendNotificationVolume: (v) async => tag.writes.add('0x11:$v'),
      sendSosVolume: (v) async => tag.writes.add('0x12:$v'),
      fetchProvisioningConfig: () async {
        configFetches++;
        if (!configAvailable) throw StateError('no location');
        return config;
      },
      sendAckCommand: tag.ack,
      reboot: tag.reboot,
      isLinkUp: () => linkUp,
      repairLedger: ledger,
      clock: clock.now,
    );
    bootstrap.events.listen(events.add);
    return bootstrap;
  }

  List<TagSessionBootstrapCode> get codes =>
      events.map((event) => event.code).toList();

  List<String> get radioWrites => tag.writes
      .where((w) => w == '0x20' || w == '0x21' || w == '0x22')
      .toList();

  void connect(
    FakeAsync async,
    String session, {
    List<String> keys = const <String>['hw-1', 'node:1'],
  }) {
    unawaited(bootstrap.start(sessionId: session, deviceKeys: keys));
    async.flushMicrotasks();
  }
}

void main() {
  setUp(() => sdkReleaseLogSinkForTesting = (_) {});
  tearDown(() => sdkReleaseLogSinkForTesting = null);

  group('TagSessionBootstrap order and SOS evidence', () {
    test('reads 0x23 first, decides SOS evidence, then volume and radio', () {
      fakeAsync((async) {
        final env = _Env(_status());
        env.build(async);
        env.connect(async, 's1');

        expect(env.tag.writes, <String>['0x23', '0x11:10', '0x12:10']);
        expect(env.codes, <TagSessionBootstrapCode>[
          TagSessionBootstrapCode.sosEvidenceUnavailable,
          TagSessionBootstrapCode.volumeRestored,
          TagSessionBootstrapCode.radioOk,
        ]);
      });
    });

    test('status v2 (old firmware) never yields SOS evidence', () {
      final bootstrap = TagSessionBootstrap(
        readStatus: () async => _status(),
        sosHold: () async => null,
        radioWriteHold: () async => null,
        lastSosFrameAt: () => null,
        volumeStore: _MemoryVolumeStore(),
        sendNotificationVolume: (_) async {},
        sendSosVolume: (_) async {},
        fetchProvisioningConfig: () async => _config,
        sendAckCommand: (_, _) async => ProvisioningCommandOutcome.ok,
        reboot: () async {},
      );
      // Today's 14 B reply (E9 78 02) as the SDK receives it.
      final v2 = _status(
        rawBytes: const <int>[
          0xE9,
          0x78,
          0x02,
          3,
          0,
          9,
          5,
          1,
          0,
          0,
          0,
          80,
          45,
          0,
        ],
      );
      expect(bootstrap.sosEvidence(v2), isA<TagSosEvidenceUnavailable>());
      expect(
        bootstrap.sosEvidence(_longFast()),
        isA<TagSosEvidenceUnavailable>(),
      );
    });

    test('the contract handshake hook runs before the 0x23 read', () {
      fakeAsync((async) {
        final env = _Env(_status());
        final order = <String>[];
        final clock = async.getClock(DateTime.utc(2026));
        final bootstrap = TagSessionBootstrap(
          readStatus: () async {
            order.add('0x23');
            return _status();
          },
          contractHandshake: () async {
            order.add('handshake');
            return 1;
          },
          sosHold: () async => null,
          radioWriteHold: () async => null,
          lastSosFrameAt: () => null,
          volumeStore: env.volumes,
          sendNotificationVolume: (_) async {},
          sendSosVolume: (_) async {},
          fetchProvisioningConfig: () async => _config,
          sendAckCommand: (_, _) async => ProvisioningCommandOutcome.ok,
          reboot: () async {},
          clock: clock.now,
        );
        unawaited(
          bootstrap.start(sessionId: 's', deviceKeys: const <String>['k']),
        );
        async.flushMicrotasks();
        expect(order, <String>['handshake', '0x23']);
      });
    });

    test('runs once per connection session', () {
      fakeAsync((async) {
        final env = _Env(_status());
        env.build(async);
        env.connect(async, 's1');
        env.connect(async, 's1');
        expect(env.tag.statusReads, 1);
        env.connect(async, 's2');
        expect(env.tag.statusReads, 2);
      });
    });

    test('a failed 0x23 read writes nothing', () {
      fakeAsync((async) {
        final env = _Env(_status());
        final clock = async.getClock(DateTime.utc(2026));
        final bootstrap = TagSessionBootstrap(
          readStatus: () async => throw const DeviceException('E', 'E'),
          sosHold: () async => null,
          radioWriteHold: () async => null,
          lastSosFrameAt: () => null,
          volumeStore: env.volumes,
          sendNotificationVolume: (v) async => env.tag.writes.add('0x11:$v'),
          sendSosVolume: (v) async => env.tag.writes.add('0x12:$v'),
          fetchProvisioningConfig: () async => _config,
          sendAckCommand: env.tag.ack,
          reboot: env.tag.reboot,
          clock: clock.now,
        );
        final events = <TagSessionBootstrapEvent>[];
        bootstrap.events.listen(events.add);
        unawaited(
          bootstrap.start(sessionId: 's', deviceKeys: const <String>['hw-1']),
        );
        async.elapse(const Duration(minutes: 3));
        expect(env.tag.writes, isEmpty);
        expect(events.single.code, TagSessionBootstrapCode.statusReadFailed);
      });
    });
  });

  group('doc 36 §9 evidence and §7.1 handshake', () {
    test('parses the §9 example 1:1', () {
      final evidence = TagSessionSosEvidence.fromStatusReply(
        _v3Reply(
          activeCycle: 0x1A2B3C4D,
          sosState: 2,
          pending: <int>[0x0F0E0D0C],
        ),
      );
      expect(evidence, isA<TagSosEvidenceReported>());
      final reported = evidence as TagSosEvidenceReported;
      expect(reported.activeCycle, 0x1A2B3C4D);
      expect(reported.sosState, TagSosState.active);
      expect(reported.pendingCycles, <int>[0x0F0E0D0C]);
      expect(
        _v3Reply(activeCycle: 1, sosState: 2, pending: <int>[2]),
        hasLength(24),
      );
    });

    test('a malformed v3 reply is unavailable, never guessed', () {
      final good = _v3Reply(sosState: 1, pending: <int>[7, 8]);
      final wrongLength = List<int>.of(good)..removeLast();
      final tooMany = _v3Reply(sosState: 1, pending: <int>[1, 2, 3, 4, 5]);
      final unknownState = _v3Reply(sosState: 9);
      for (final bytes in <List<int>>[wrongLength, tooMany, unknownState]) {
        expect(
          TagSessionSosEvidence.fromStatusReply(bytes),
          isA<TagSosEvidenceUnavailable>(),
        );
      }
      expect(
        TagSessionSosEvidence.fromStatusReply(good),
        isA<TagSosEvidenceReported>(),
      );
    });

    test(
      '0x0E 02: only OK activates v2; reject, no-change, timeout stay v1',
      () async {
        final sent = <List<int>>[];
        Future<int> negotiate(Object outcomeOrError) =>
            negotiateTagBleContractV2((opcode, bytes) async {
              expect(opcode, 0x0E);
              sent.add(bytes);
              if (outcomeOrError is ProvisioningCommandOutcome) {
                return outcomeOrError;
              }
              throw outcomeOrError;
            });
        expect(await negotiate(ProvisioningCommandOutcome.ok), 2);
        expect(await negotiate(ProvisioningCommandOutcome.okNoChange), 1);
        expect(
          await negotiate(
            const ProvisioningCommandRejectedException(opcode: 0x0E),
          ),
          1,
        );
        expect(
          await negotiate(
            const ProvisioningCommandTimeoutException(opcode: 0x0E),
          ),
          1,
        );
        expect(sent.first, <int>[0x0E, 0x02]);
      },
    );

    test(
      'a TAG reporting an open SOS holds volume and radio until it ends',
      () {
        fakeAsync((async) {
          final env = _Env(
            _status(
              usePreset: true,
              sf: 11,
              rawBytes: _v3Reply(activeCycle: 5, sosState: 2),
            ),
          );
          final reported = <TagSosEvidenceReported>[];
          final clock = async.getClock(DateTime.utc(2026));
          final bootstrap = TagSessionBootstrap(
            readStatus: env.tag.read,
            sosHold: () async => null, // the SDK itself sees no SOS
            radioWriteHold: () async => null,
            lastSosFrameAt: () => null,
            volumeStore: env.volumes,
            sendNotificationVolume: (v) async => env.tag.writes.add('0x11:$v'),
            sendSosVolume: (v) async => env.tag.writes.add('0x12:$v'),
            fetchProvisioningConfig: () async => _config,
            sendAckCommand: env.tag.ack,
            reboot: env.tag.reboot,
            onSosEvidence: reported.add,
            clock: clock.now,
          );
          env.volumes.values['hw-1'] = const TagVolumes(
            notification: 10,
            sos: 10,
          );
          unawaited(
            bootstrap.start(sessionId: 's', deviceKeys: const <String>['hw-1']),
          );
          async.elapse(const Duration(minutes: 3));
          expect(reported.single.activeCycle, 5);
          expect(env.tag.writes.where((w) => w != '0x23'), isEmpty);

          // The TAG's SOS ends; the next re-check sees it.
          env.tag.status = _status(
            usePreset: true,
            sf: 11,
            rawBytes: _v3Reply(sosState: 0),
          );
          async.elapse(TagSessionBootstrap.defaultHoldRecheck);
          expect(
            env.tag.writes,
            containsAllInOrder(<String>['0x11:10', '0x12:10']),
          );
          async.elapse(_quiet);
          expect(env.radioWrites, <String>['0x20', '0x21', '0x22']);
        });
      },
    );
  });

  group('volume', () {
    test('re-sends the stored volume on every connection', () {
      fakeAsync((async) {
        final env = _Env(_status(), storedVolume: 0);
        env.build(async);
        env.connect(async, 's1');
        env.connect(async, 's2');
        expect(env.tag.writes.where((w) => w.startsWith('0x1')), <String>[
          '0x11:0',
          '0x12:0',
          '0x11:0',
          '0x12:0',
        ]);
      });
    });

    test('nothing stored: nothing sent', () {
      fakeAsync((async) {
        final env = _Env(_status(), storedVolume: null);
        env.build(async);
        env.connect(async, 's1');
        expect(env.tag.writes, <String>['0x23']);
        expect(env.codes, contains(TagSessionBootstrapCode.volumeNotStored));
      });
    });

    test('SOS active: deferred, sent once when the SOS clears', () {
      fakeAsync((async) {
        final env = _Env(_status())..sosHold = 'sos_active';
        env.build(async);
        env.connect(async, 's1');
        async.elapse(const Duration(seconds: 40));
        expect(env.tag.writes, <String>['0x23']);
        expect(
          env.events.where(
            (e) => e.code == TagSessionBootstrapCode.deferredForSafety,
          ),
          hasLength(1),
        );

        env.sosHold = null;
        env.bootstrap.safetyMayHaveCleared();
        async.flushMicrotasks();
        expect(env.tag.writes, <String>['0x23', '0x11:10', '0x12:10']);
        async.elapse(const Duration(minutes: 2));
        expect(env.tag.writes.where((w) => w.startsWith('0x1')), hasLength(2));
      });
    });

    test('a deferred tail resumes on its own re-check', () {
      fakeAsync((async) {
        final env = _Env(_status())..sosHold = 'sos_prompt_open';
        env.build(async);
        env.connect(async, 's1');
        env.sosHold = null;
        async.elapse(TagSessionBootstrap.defaultHoldRecheck);
        expect(env.tag.writes, <String>['0x23', '0x11:10', '0x12:10']);
      });
    });

    test('link lost while deferred: nothing is sent', () {
      fakeAsync((async) {
        final env = _Env(_status())..sosHold = 'sos_active';
        env.build(async);
        env.connect(async, 's1');
        env
          ..linkUp = false
          ..sosHold = null;
        async.elapse(const Duration(minutes: 2));
        expect(env.tag.writes, <String>['0x23']);
      });
    });
  });

  group('radio', () {
    test('correct radio: never written', () {
      fakeAsync((async) {
        final env = _Env(_status(sf: 7)); // adaptive SF inside the envelope
        env.build(async);
        env.connect(async, 's1');
        async.elapse(const Duration(minutes: 5));
        expect(env.radioWrites, isEmpty);
        expect(env.configFetches, 0);
      });
    });

    test('wrong radio: waits for a quiet TAG, then repairs exactly once', () {
      fakeAsync((async) {
        final env = _Env(_longFast());
        env.build(async);
        env.connect(async, 's1');
        expect(
          env.codes,
          contains(TagSessionBootstrapCode.radioAwaitingQuietTag),
        );

        async.elapse(_quiet - const Duration(seconds: 1));
        expect(env.radioWrites, isEmpty);

        async.elapse(const Duration(seconds: 1));
        expect(env.radioWrites, <String>['0x20', '0x21', '0x22']);
        expect(
          env.codes,
          containsAllInOrder(<TagSessionBootstrapCode>[
            TagSessionBootstrapCode.radioRepairStarted,
            TagSessionBootstrapCode.radioRepairRebooting,
          ]),
        );
        // 0x23 re-read right before the repair.
        expect(env.tag.statusReads, 2);

        async.elapse(const Duration(minutes: 10));
        env.bootstrap.safetyMayHaveCleared();
        async.flushMicrotasks();
        expect(env.radioWrites, hasLength(3));
      });
    });

    test('next connection verifies a good repair', () {
      fakeAsync((async) {
        final env = _Env(_longFast());
        env.build(async);
        env.connect(async, 's1');
        async.elapse(_quiet);
        env.connect(async, 's2');
        expect(
          env.codes,
          contains(TagSessionBootstrapCode.radioRepairVerified),
        );
        expect(
          env.codes,
          isNot(contains(TagSessionBootstrapCode.radioRepairFailed)),
        );
        // Volume is re-sent after the repair reboot.
        expect(env.tag.writes.where((w) => w == '0x12:10'), hasLength(2));
      });
    });

    test('repair fails: diagnostic and no retry loop', () {
      fakeAsync((async) {
        final env = _Env(_longFast());
        env.tag.appliesOnReboot = false;
        env.build(async);
        env.connect(async, 's1');
        async.elapse(_quiet);
        expect(env.radioWrites, <String>['0x20', '0x21', '0x22']);

        env.connect(async, 's2');
        expect(env.codes, contains(TagSessionBootstrapCode.radioRepairFailed));
        async.elapse(const Duration(minutes: 5));
        env.connect(async, 's3');
        async.elapse(const Duration(minutes: 5));

        expect(env.radioWrites, <String>['0x20', '0x21', '0x22']);
        expect(
          env.events.where(
            (e) =>
                e.code == TagSessionBootstrapCode.radioRepairSkipped &&
                e.reason == 'blocked',
          ),
          hasLength(2),
        );
      });
    });

    test('firmware ignores the RF block (OK_NOCHANGE on use_preset): '
        'no reboot', () {
      fakeAsync((async) {
        final env = _Env(_longFast());
        env.tag.radioOutcome = ProvisioningCommandOutcome.okNoChange;
        env.build(async);
        env.connect(async, 's1');
        async.elapse(_quiet);
        expect(env.radioWrites, <String>['0x20']);
        expect(
          env.codes,
          contains(TagSessionBootstrapCode.radioRepairNotApplied),
        );
        env.connect(async, 's2');
        async.elapse(const Duration(minutes: 2));
        expect(env.radioWrites, <String>['0x20']);
      });
    });

    test('OK_NOCHANGE never reboots (saved config already right)', () {
      fakeAsync((async) {
        final env = _Env(_status(sf: 11)); // use_preset already cleared
        env.tag.radioOutcome = ProvisioningCommandOutcome.okNoChange;
        env.build(async);
        env.connect(async, 's1');
        async.elapse(_quiet);
        expect(env.radioWrites, <String>['0x20']);
        expect(
          env.events.any((e) => e.reason == 'saved_config_matches'),
          isTrue,
        );
        env.connect(async, 's2');
        async.elapse(_quiet * 2);
        expect(env.radioWrites, <String>['0x20']);
      });
    });

    test('live SF = the SOS PHY SF: treated as a possible SOS, untouched', () {
      fakeAsync((async) {
        // A backend SOS profile outside the TEL envelope (SF10); the TAG on
        // its SOS PHY reports that SF live.
        final env = _Env(_status(sf: 10))
          ..config = const StrictDeviceProvisioningConfig(
            regionCode: 3,
            region: 'EU868',
            tel: ProvisioningTelConfig(
              frequencyKhz: 866500,
              bandwidthKhz: 250,
              spreadingFactor: 9,
              codingRateDenominator: 5,
              txPowerDbm: 14,
            ),
            sos: ProvisioningSosConfig(
              frequencyHz: 869618000,
              bandwidthHz: 62500,
              spreadingFactor: 10,
              codingRateDenominator: 5,
              txPowerDbm: 27,
              preambleSymbols: 16,
            ),
          );
        env.build(async);
        env.connect(async, 's1');
        async.elapse(_quiet * 2);
        expect(env.radioWrites, isEmpty);
        expect(env.events.any((e) => e.reason == 'sos_phy_possible'), isTrue);
      });
    });

    test('verification matches any of the TAG\'s keys', () {
      fakeAsync((async) {
        final env = _Env(_longFast());
        env.tag.appliesOnReboot = false;
        env.build(async);
        env.connect(async, 's1', keys: const <String>['hw-1', 'node:1']);
        async.elapse(_quiet);
        // Canonical id not known yet on the next link: node id only.
        env.connect(async, 's2', keys: const <String>['node:1']);
        expect(env.codes, contains(TagSessionBootstrapCode.radioRepairFailed));
        async.elapse(_quiet * 2);
        expect(env.radioWrites, <String>['0x20', '0x21', '0x22']);
      });
    });

    test('a block survives an app restart and expires after 24 h', () {
      fakeAsync((async) {
        final ledger = InMemoryTagRadioRepairLedger();
        final first = _Env(_longFast())..ledger = ledger;
        first.tag.appliesOnReboot = false;
        first.build(async);
        first.connect(async, 's1');
        async.elapse(_quiet);
        first.connect(async, 's2'); // verification fails -> blocked
        expect(
          first.codes,
          contains(TagSessionBootstrapCode.radioRepairFailed),
        );
        unawaited(first.bootstrap.dispose());

        // App restart: a new bootstrap, the same persisted ledger.
        final second = _Env(_longFast())..ledger = ledger;
        second.build(async);
        second.connect(async, 'r1');
        async.elapse(_quiet * 2);
        expect(second.radioWrites, isEmpty);
        expect(second.events.any((e) => e.reason == 'blocked'), isTrue);

        async.elapse(const Duration(hours: 24));
        second.connect(async, 'r2');
        async.elapse(_quiet);
        expect(second.radioWrites, <String>['0x20', '0x21', '0x22']);
      });
    });

    test('contract v2 with no SOS evidence in the reply: held, never '
        'treated as "no SOS"', () {
      fakeAsync((async) {
        final env = _Env(_longFast());
        final clock = async.getClock(DateTime.utc(2026));
        final bootstrap = TagSessionBootstrap(
          readStatus: env.tag.read, // 14 B v2 reply although v2 is active
          contractHandshake: () async => 2,
          sosHold: () async => null,
          radioWriteHold: () async => null,
          lastSosFrameAt: () => null,
          volumeStore: env.volumes,
          sendNotificationVolume: (v) async => env.tag.writes.add('0x11:$v'),
          sendSosVolume: (v) async => env.tag.writes.add('0x12:$v'),
          fetchProvisioningConfig: () async => _config,
          sendAckCommand: env.tag.ack,
          reboot: env.tag.reboot,
          clock: clock.now,
        );
        env.volumes.values['hw-1'] = const TagVolumes(
          notification: 10,
          sos: 10,
        );
        final events = <TagSessionBootstrapEvent>[];
        bootstrap.events.listen(events.add);
        unawaited(
          bootstrap.start(sessionId: 's', deviceKeys: const <String>['hw-1']),
        );
        async.elapse(_quiet * 2);
        expect(env.tag.writes.where((w) => w != '0x23'), isEmpty);
        expect(events.any((e) => e.reason == 'tag_sos_unknown'), isTrue);
      });
    });

    test('write failure: diagnostic, no reboot, no retry', () {
      fakeAsync((async) {
        final env = _Env(_longFast());
        env.tag.radioError = const ProvisioningCommandTimeoutException(
          opcode: 0x20,
        );
        env.build(async);
        env.connect(async, 's1');
        async.elapse(_quiet);
        env.connect(async, 's2');
        async.elapse(const Duration(minutes: 2));
        expect(env.radioWrites, <String>['0x20']);
        expect(
          env.codes,
          contains(TagSessionBootstrapCode.radioRepairWriteFailed),
        );
      });
    });

    test('SOS active: radio never written while it lasts', () {
      fakeAsync((async) {
        final env = _Env(_longFast())..sosHold = 'sos_active';
        env.build(async);
        env.connect(async, 's1');
        async.elapse(const Duration(minutes: 10));
        expect(env.radioWrites, isEmpty);
        expect(env.configFetches, 0);
      });
    });

    test('countdown (TAG preConfirm) starting during the repair: '
        'no reboot', () {
      fakeAsync((async) {
        final env = _Env(_longFast());
        // The TAG countdown starts right after the 0x20 write.
        final ack = env.tag.ack;
        var calls = 0;
        final bootstrap = TagSessionBootstrap(
          readStatus: env.tag.read,
          sosHold: () async => calls >= 1 ? 'sos_active' : null,
          radioWriteHold: () async => null,
          lastSosFrameAt: () => null,
          volumeStore: env.volumes,
          sendNotificationVolume: (_) async {},
          sendSosVolume: (_) async {},
          fetchProvisioningConfig: () async => _config,
          sendAckCommand: (opcode, bytes) async {
            calls++;
            return ack(opcode, bytes);
          },
          reboot: env.tag.reboot,
          clock: async.getClock(DateTime.utc(2026)).now,
        );
        final events = <TagSessionBootstrapEvent>[];
        bootstrap.events.listen(events.add);
        unawaited(
          bootstrap.start(sessionId: 'x', deviceKeys: const <String>['hw-2']),
        );
        async.elapse(_quiet);
        expect(env.radioWrites, <String>['0x20']);
        expect(
          events.map((e) => e.code),
          contains(TagSessionBootstrapCode.radioRepairRebootSkipped),
        );
      });
    });

    test('an SOS frame inside the quiet window postpones the repair', () {
      fakeAsync((async) {
        final env = _Env(_longFast());
        env.build(async);
        final start = async.getClock(DateTime.utc(2026, 11, 19, 12)).now();
        env.connect(async, 's1');
        const frameAt = Duration(seconds: 50);
        async.elapse(frameAt);
        // The TAG was ringing: one of its retries arrives.
        env.lastSosFrameAt = start.add(frameAt);
        async.elapse(_quiet - frameAt); // quiet window since connect
        expect(env.radioWrites, isEmpty);
        async.elapse(frameAt - const Duration(seconds: 1));
        expect(env.radioWrites, isEmpty);
        async.elapse(const Duration(seconds: 1)); // quiet since the frame
        expect(env.radioWrites, <String>['0x20', '0x21', '0x22']);
      });
    });

    test('native owner / OTA / DMP hold: skipped for this connection', () {
      fakeAsync((async) {
        final env = _Env(_longFast())..radioHold = 'native_owner';
        env.build(async);
        env.connect(async, 's1');
        async.elapse(const Duration(minutes: 3));
        expect(env.radioWrites, isEmpty);
        expect(
          env.events.where((e) => e.reason == 'native_owner'),
          hasLength(1),
        );
        env.radioHold = null;
        env.connect(async, 's2');
        async.elapse(_quiet);
        expect(env.radioWrites, <String>['0x20', '0x21', '0x22']);
      });
    });

    test('TAG region differs from the backend: left to the country check', () {
      fakeAsync((async) {
        final env = _Env(_status(region: 1, usePreset: true, sf: 11));
        env.build(async);
        env.connect(async, 's1');
        async.elapse(_quiet);
        expect(env.radioWrites, isEmpty);
        expect(env.events.any((e) => e.reason == 'region_mismatch'), isTrue);
      });
    });

    test('no location/config: skipped, nothing invented', () {
      fakeAsync((async) {
        final env = _Env(_longFast())..configAvailable = false;
        env.build(async);
        env.connect(async, 's1');
        async.elapse(_quiet);
        expect(env.radioWrites, isEmpty);
        expect(env.events.any((e) => e.reason == 'config_unavailable'), isTrue);
      });
    });

    test('tx disabled: diagnostic only (the RF block cannot fix it)', () {
      fakeAsync((async) {
        final env = _Env(_status(txEnabled: false, usePreset: true, sf: 11));
        env.build(async);
        env.connect(async, 's1');
        async.elapse(const Duration(minutes: 3));
        expect(env.radioWrites, isEmpty);
        expect(env.codes, contains(TagSessionBootstrapCode.radioTxDisabled));
      });
    });

    test('not provisioned: provisioning owns the radio', () {
      fakeAsync((async) {
        final env = _Env(_status(provisioned: false, usePreset: true, sf: 11));
        env.build(async);
        env.connect(async, 's1');
        async.elapse(const Duration(minutes: 3));
        expect(env.radioWrites, isEmpty);
      });
    });

    test('link lost before the quiet window ends: nothing written', () {
      fakeAsync((async) {
        final env = _Env(_longFast());
        env.build(async);
        env.connect(async, 's1');
        async.elapse(const Duration(seconds: 30));
        env.linkUp = false;
        async.elapse(const Duration(minutes: 2));
        expect(env.radioWrites, isEmpty);
      });
    });
  });

  group('SharedPrefsTagVolumeStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('writes under every key, reads the first known one', () async {
      final store = SharedPrefsTagVolumeStore(SharedPrefsSdkStore());
      await store.write(const <String>['HW-1', 'node:7'], sos: 10);
      await store.write(const <String>['hw-1'], notification: 20);

      final byHardware = await store.read(const <String>['hw-1']);
      expect(byHardware?.notification, 20);
      expect(byHardware?.sos, 10);
      final byNode = await store.read(const <String>['', 'node:7']);
      expect(byNode?.sos, 10);
      expect(byNode?.notification, isNull);
      expect(await store.read(const <String>['other']), isNull);
    });

    test('reads the newest value across aliases (review M1)', () async {
      var now = DateTime.utc(2026, 11, 19, 10);
      final store = SharedPrefsTagVolumeStore(
        SharedPrefsSdkStore(),
        clock: () => now,
      );
      await store.write(const <String>['hw-1', 'node:7'], sos: 80);
      now = now.add(const Duration(minutes: 1));
      // Canonical id unknown at this write.
      await store.write(const <String>['node:7'], sos: 10);
      final read = await store.read(const <String>['hw-1', 'node:7']);
      expect(read?.sos, 10);
    });

    test('is part of the SDK local user data (cleared with it)', () {
      expect(
        SharedPrefsSdkStore.localUserDataKeys,
        containsAll(<String>[
          SharedPrefsSdkStore.tagVolumesKey,
          SharedPrefsSdkStore.tagRadioRepairKey,
        ]),
      );
    });

    test('repair ledger persists marks per alias, newest wins', () async {
      final ledger = SharedPrefsTagRadioRepairLedger(SharedPrefsSdkStore());
      final t0 = DateTime.utc(2026, 11, 19, 10);
      await ledger.write(const <String>[
        'HW-1',
        'node:7',
      ], TagRadioRepairMark(TagRadioRepairState.awaitingVerification, t0));
      await ledger.write(
        const <String>['node:7'],
        TagRadioRepairMark(
          TagRadioRepairState.blocked,
          t0.add(const Duration(minutes: 1)),
        ),
      );
      final mark = await SharedPrefsTagRadioRepairLedger(
        SharedPrefsSdkStore(),
      ).read(const <String>['hw-1', 'node:7']);
      expect(mark?.state, TagRadioRepairState.blocked);
      await ledger.write(const <String>['hw-1', 'node:7'], null);
      expect(await ledger.read(const <String>['hw-1', 'node:7']), isNull);
    });
  });

  test('TEL SF envelope comes from the provisioning regulatory table', () {
    expect(provisioningTelSpreadingFactorRange(3), (min: 7, max: 9));
    expect(provisioningTelSpreadingFactorRange(1), isNull);
  });
}
