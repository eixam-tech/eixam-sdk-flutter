import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/own_tag_sos_frame_gate.dart';
import 'package:eixam_connect_flutter/src/diagnostics/sdk_release_log.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/device/mock_ble_client.dart';

/// F17c: Dart's side of the single stale-SOS decision point. Native classifies
/// (Swift and Kotlin replay the same fixture against the real store); Dart only
/// forwards every own-TAG frame it receives and acts on the verdict. This test
/// replays the fixture's Dart-path frames through the channel contract fake.
void main() {
  group('shared stale-SOS fixture, Dart side of the channel contract', () {
    final fixture = File('test/fixtures/stale_sos_guard_scenarios.txt');

    test('every Dart-received frame is forwarded in order; only proceed and '
        'newSos verdicts reach the device SOS state', () async {
      expect(fixture.existsSync(), isTrue);
      var scenarios = 0;
      var dartFrames = 0;
      String? name;
      late OwnTagSosFrameGate gate;
      late List<OwnTagSosFrameReport> forwarded;
      late List<String> processed;
      final expectedVerdicts = <OwnTagSosFrameVerdict>[];

      for (final raw in fixture.readAsLinesSync()) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) {
          continue;
        }
        if (line.startsWith('scenario ')) {
          name = line.substring('scenario '.length);
          scenarios++;
          gate = OwnTagSosFrameGate();
          forwarded = <OwnTagSosFrameReport>[];
          processed = <String>[];
          expectedVerdicts.clear();
          gate.setClassifier((frame) async {
            forwarded.add(frame);
            if (frame.isClose) {
              return OwnTagSosFrameVerdict.proceed;
            }
            // The native verdict the Swift/Kotlin replays assert for this line.
            return expectedVerdicts.removeAt(0);
          });
          continue;
        }
        final parts = line.split(' => ');
        final event = parts[0].split(' ');
        final expected = parts[1].split(' ').first;
        final args = <String, String>{
          for (final token in event.skip(2))
            if (token.contains('='))
              token.split('=').first: token.split('=').last,
        };
        final label = '$name @${event[0]} ${event[1]}';
        if (args['source'] != 'dart') {
          continue; // native-path frames never reach Dart's gate
        }
        switch (event[1]) {
          case 'frame':
            final verdict = switch (expected) {
              'pass' => OwnTagSosFrameVerdict.proceed,
              'newSos' => OwnTagSosFrameVerdict.newSos,
              _ => OwnTagSosFrameVerdict.suppress,
            };
            expectedVerdicts.add(verdict);
            final before = forwarded.length;
            final processedBefore = processed.length;
            gate.submitStartFrame(
              OwnTagSosFrameReport(
                bytes: const <int>[0x07, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x80],
                characteristic: 'sos',
                receivedAt: DateTime.now(),
              ),
              () => processed.add(label),
            );
            await gate.idle;
            dartFrames++;
            expect(forwarded.length, before + 1, reason: '$label: forwarded');
            expect(
              processed.length - processedBefore,
              verdict == OwnTagSosFrameVerdict.suppress ? 0 : 1,
              reason: '$label: Dart acts only on $verdict',
            );
          case 'close':
            final before = forwarded.length;
            gate.forwardCloseFrame(
              OwnTagSosFrameReport(
                bytes: const <int>[0xE1, 0x02, 0x07, 0, 0, 0],
                characteristic: 'sos',
                receivedAt: DateTime.now(),
                isClose: true,
              ),
            );
            await gate.idle;
            expect(forwarded.length, before + 1, reason: '$label: forwarded');
            expect(forwarded.last.isClose, isTrue);
          case 'seen':
            break;
          default:
            fail('$label: unexpected Dart-path event');
        }
      }
      expect(scenarios, greaterThan(15));
      expect(dartFrames, greaterThan(20));
    });

    test('without a native classifier frames are handled synchronously, as '
        'before F17c', () {
      final gate = OwnTagSosFrameGate();
      var processed = 0;
      gate.submitStartFrame(
        OwnTagSosFrameReport(
          bytes: const <int>[1],
          characteristic: 'sos',
          receivedAt: DateTime.now(),
        ),
        () => processed++,
      );
      expect(processed, 1);
    });

    test('a throwing classifier fails open', () async {
      final gate = OwnTagSosFrameGate()
        ..setClassifier((_) async => throw StateError('channel'));
      var processed = 0;
      gate.submitStartFrame(
        OwnTagSosFrameReport(
          bytes: const <int>[1],
          characteristic: 'sos',
          receivedAt: DateTime.now(),
        ),
        () => processed++,
      );
      await gate.idle;
      expect(processed, 1);
    });

    test(
      'H-B: a throwing frame handler never breaks the chain; later frames '
      'are still classified and handled, and the error is release-logged',
      () async {
        final releaseLines = <String>[];
        sdkReleaseLogSinkForTesting = releaseLines.add;
        addTearDown(() => sdkReleaseLogSinkForTesting = null);
        final gate = OwnTagSosFrameGate();
        final classified = <int>[];
        gate.setClassifier((frame) async {
          classified.add(frame.bytes.first);
          return OwnTagSosFrameVerdict.proceed;
        });
        final handled = <String>[];
        OwnTagSosFrameReport report(int id, {bool close = false}) =>
            OwnTagSosFrameReport(
              bytes: <int>[id],
              characteristic: 'sos',
              receivedAt: DateTime.now(),
              isClose: close,
            );
        gate.submitStartFrame(report(1), () => throw StateError('frame 1'));
        gate.submitEventFrame(
          report(2, close: true),
          () => throw StateError('event 2'),
        );
        gate.submitStartFrame(report(3), () => handled.add('start 3'));
        gate.submitEventFrame(report(4), () => handled.add('event 4'));
        await gate.idle;
        expect(classified, <int>[
          1,
          2,
          3,
        ], reason: 'every frame reaches native');
        expect(handled, <String>['start 3', 'event 4']);
        expect(
          releaseLines.where(
            (line) => line.startsWith('SOS_OUTBOX_STALE_GATE_HANDLER_FAILED'),
          ),
          hasLength(2),
        );
      },
    );

    test('a suppressed frame is release-logged', () async {
      final releaseLines = <String>[];
      sdkReleaseLogSinkForTesting = releaseLines.add;
      addTearDown(() => sdkReleaseLogSinkForTesting = null);
      final gate = OwnTagSosFrameGate()
        ..setClassifier((_) async => OwnTagSosFrameVerdict.suppress);
      var processed = 0;
      gate.submitStartFrame(
        OwnTagSosFrameReport(
          bytes: const <int>[1],
          characteristic: 'tel',
          receivedAt: DateTime.now(),
        ),
        () => processed++,
      );
      await gate.idle;
      expect(processed, 0);
      expect(
        releaseLines,
        contains('SOS_OUTBOX_STALE_FRAME_SUPPRESSED characteristic=tel'),
      );
    });

    test('a TAG close frame never overtakes an earlier SOS push still being '
        'classified', () async {
      final gate = OwnTagSosFrameGate();
      final verdict = Completer<OwnTagSosFrameVerdict>();
      final forwarded = <bool>[];
      gate.setClassifier((frame) {
        forwarded.add(frame.isClose);
        return frame.isClose
            ? Future<OwnTagSosFrameVerdict>.value(OwnTagSosFrameVerdict.proceed)
            : verdict.future;
      });
      final order = <String>[];
      gate.submitStartFrame(
        OwnTagSosFrameReport(
          bytes: const <int>[1],
          characteristic: 'sos',
          receivedAt: DateTime.now(),
        ),
        () => order.add('sos'),
      );
      gate.submitEventFrame(
        OwnTagSosFrameReport(
          bytes: const <int>[0xE1, 0x02, 0, 0, 0, 0],
          characteristic: 'sos',
          receivedAt: DateTime.now(),
          isClose: true,
        ),
        () => order.add('close'),
      );
      await pumpEventQueue();
      expect(order, isEmpty, reason: 'the close waits behind the SOS push');
      verdict.complete(OwnTagSosFrameVerdict.proceed);
      await gate.idle;
      expect(order, <String>['sos', 'close']);
      expect(forwarded, <bool>[false, true]);
    });

    test('frames keep their arrival order across slow verdicts', () async {
      final gate = OwnTagSosFrameGate();
      var call = 0;
      gate.setClassifier((_) async {
        final delay = (call++ == 0) ? 50 : 0;
        await Future<void>.delayed(Duration(milliseconds: delay));
        return OwnTagSosFrameVerdict.proceed;
      });
      final order = <int>[];
      for (var i = 0; i < 3; i++) {
        gate.submitStartFrame(
          OwnTagSosFrameReport(
            bytes: <int>[i],
            characteristic: 'sos',
            receivedAt: DateTime.now(),
          ),
          () => order.add(i),
        );
      }
      await gate.idle;
      expect(order, <int>[0, 1, 2]);
    });
  });

  group('BleDeviceRuntimeProvider routes own-TAG frames through the gate', () {
    const startPayload = <int>[
      0x34,
      0x12,
      0x00,
      0x00,
      0x48,
      0xCD,
      0x1B,
      0x34,
      0x44,
      0x28,
      0x00,
      0xC0,
    ];
    const closePayload = <int>[0xE1, 0x02, 0x34, 0x12, 0x00, 0x00];

    Future<
      ({
        MockBleClient ble,
        BleDeviceRuntimeProvider provider,
        DeviceSosController controller,
      })
    >
    start() async {
      final controller = DeviceSosController();
      final ble = MockBleClient();
      final provider = BleDeviceRuntimeProvider(
        bleClient: ble,
        deviceSosController: controller,
      );
      await ble.initialize();
      BleDebugRegistry.instance.update(
        selectedDeviceId: MockBleClient.demoDeviceId,
      );
      await provider.pair(
        currentStatus: buildDeviceStatus(
          paired: false,
          activated: false,
          connected: false,
          lifecycleState: DeviceLifecycleState.unpaired,
        ),
        pairingCode: '1234',
      );
      return (ble: ble, provider: provider, controller: controller);
    }

    Future<void> emit(
      MockBleClient ble,
      BleDeviceRuntimeProvider provider,
      EixamBleChannel channel,
      List<int> payload,
      BleIncomingEventType type,
    ) async {
      final event = provider.watchIncomingEvents().firstWhere(
        (candidate) => candidate.type == type,
      );
      ble.emitNotification(
        MockBleClient.demoDeviceId,
        channel: channel,
        payload: payload,
      );
      await event;
      await pumpEventQueue(times: 10);
    }

    for (final verdict in OwnTagSosFrameVerdict.values) {
      test('verdict ${verdict.name}', () async {
        final env = await start();
        final frames = <OwnTagSosFrameReport>[];
        env.controller.setOwnTagSosFrameClassifier((frame) async {
          frames.add(frame);
          return verdict;
        });
        try {
          await emit(
            env.ble,
            env.provider,
            EixamBleChannel.sos,
            startPayload,
            BleIncomingEventType.sosMeshPacket,
          );
          await env.controller.ownTagSosFrameGate.idle;
          await pumpEventQueue(times: 10);
          expect(frames, hasLength(1));
          expect(frames.single.bytes, startPayload);
          expect(frames.single.characteristic, 'sos');
          expect(frames.single.isClose, isFalse);
          expect(
            env.controller.currentStatus.state,
            verdict == OwnTagSosFrameVerdict.suppress
                ? DeviceSosState.inactive
                : DeviceSosState.preConfirm,
          );
          await emit(
            env.ble,
            env.provider,
            EixamBleChannel.tel,
            closePayload,
            BleIncomingEventType.sosDeviceEvent,
          );
          await env.controller.ownTagSosFrameGate.idle;
          expect(frames.last.isClose, isTrue);
          expect(frames.last.characteristic, 'tel');
        } finally {
          await env.provider.dispose();
          await env.ble.dispose();
        }
      });
    }
  });
}
