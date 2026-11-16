import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:eixam_connect_flutter/src/device/own_tag_sos_frame_gate.dart';
import 'package:eixam_connect_flutter/src/diagnostics/sdk_release_log.dart';
import 'package:eixam_connect_flutter/src/sdk/ambiguous_tag_sos_prompt_tracker.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/device/mock_ble_client.dart';

/// F17c: Dart's side of the single stale-SOS decision point. Native classifies
/// (Swift and Kotlin replay the same fixture against the real store; Dart
/// cannot run either store, so the verdicts here are the ones those replays
/// assert). Dart only forwards every own-TAG frame it receives and acts on the
/// verdict: the fixture's Dart-path frames enter as raw BLE notifications
/// through BleDeviceRuntimeProvider (not the gate directly), so the routing
/// itself is under test.
class _CountingDeviceSosController extends DeviceSosController {
  int startPacketsHandled = 0;

  @override
  void handleIncomingSosPacket(
    EixamSosPacket packet, {
    required DeviceSosTransitionSource source,
    DeviceSosStateResolutionContext? resolutionContext,
  }) {
    startPacketsHandled++;
    super.handleIncomingSosPacket(
      packet,
      source: source,
      resolutionContext: resolutionContext,
    );
  }
}

void main() {
  group('shared stale-SOS fixture, Dart side of the channel contract', () {
    final fixture = File('test/fixtures/stale_sos_guard_scenarios.txt');
    const ownNode = 0x1234;

    /// One TAG SOS push (12-byte SOS frame); [variant] keeps every push
    /// distinct so Dart's own copy filter never hides what the gate decided.
    List<int> sosPush(int node, int variant) => <int>[
      node & 0xFF,
      (node >> 8) & 0xFF,
      0x00,
      0x00,
      0x48,
      0xCD,
      0x1B,
      0x34,
      variant & 0xFF,
      0x28,
      (variant >> 8) & 0x0F,
      0xC0,
    ];

    List<int> closeFrame(int node, {int opcode = 0xE1}) => <int>[
      opcode,
      // Subcode 0x02: closed with the SOS already fired/active (firmware
      // 07 §1.2: 0xE1 0x01|0x02, 0xE2/0xE3 0x01|0x02|0x03).
      0x02,
      node & 0xFF,
      (node >> 8) & 0xFF,
      0x00,
      0x00,
    ];

    test('every Dart-received own-TAG frame goes from the BLE provider to '
        'native in order; only proceed and newSos verdicts reach the device '
        'SOS state', () async {
      expect(fixture.existsSync(), isTrue);
      var scenarios = 0;
      var dartFrames = 0;
      var variant = 0;
      String? name;
      _CountingDeviceSosController? controller;
      MockBleClient? ble;
      BleDeviceRuntimeProvider? provider;
      final forwarded = <OwnTagSosFrameReport>[];
      final expectedVerdicts = <OwnTagSosFrameVerdict>[];
      // F17c prompt: native's prompt as the Swift/Kotlin replays assert it,
      // and the SDK's tracker that mirrors it for the host.
      ProtectionOwnTagSosPrompt? nativePrompt;
      var nativeAnswer = 'none';
      var promptSteps = 0;
      final base = DateTime.utc(2026, 11, 16);
      AmbiguousTagSosPromptTracker? tracker;

      Future<void> closeScenario() async {
        await provider?.dispose();
        await ble?.dispose();
        provider = null;
        ble = null;
      }

      Future<void> deliver(EixamBleChannel channel, List<int> payload) async {
        ble!.emitNotification(
          MockBleClient.demoDeviceId,
          channel: channel,
          payload: payload,
        );
        await pumpEventQueue(times: 10);
        await controller!.ownTagSosFrameGate.idle;
        await pumpEventQueue(times: 5);
      }

      try {
        for (final raw in fixture.readAsLinesSync()) {
          final line = raw.trim();
          if (line.isEmpty || line.startsWith('#')) {
            continue;
          }
          if (line.startsWith('scenario ')) {
            await closeScenario();
            await tracker?.dispose();
            nativePrompt = null;
            tracker = AmbiguousTagSosPromptTracker(
              read: () async => nativePrompt,
              answer: (_) async => nativeAnswer,
              clock: () => base,
            );
            name = line.substring('scenario '.length);
            scenarios++;
            forwarded.clear();
            expectedVerdicts.clear();
            final sosController = controller = _CountingDeviceSosController();
            final client = ble = MockBleClient();
            provider = BleDeviceRuntimeProvider(
              bleClient: client,
              deviceSosController: sosController,
            );
            await client.initialize();
            BleDebugRegistry.instance.update(
              selectedDeviceId: MockBleClient.demoDeviceId,
            );
            await provider!.pair(
              currentStatus: buildDeviceStatus(
                paired: false,
                activated: false,
                connected: false,
                lifecycleState: DeviceLifecycleState.unpaired,
              ),
              pairingCode: '1234',
            );
            sosController.setOwnTagSosFrameClassifier((frame) async {
              forwarded.add(frame);
              if (frame.isClose) {
                return OwnTagSosFrameVerdict.proceed;
              }
              // The native verdict the Swift/Kotlin replays assert here.
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
          final want = <String, String>{
            for (final token in parts[1].split(' ').skip(1))
              if (token.contains('='))
                token.split('=').first: token.split('=').last,
          };
          // Every ambiguous step asserts the prompt identically to the Swift
          // and Kotlin replays: native's prompt reaches the host (or closes).
          final shownBefore = nativePrompt;
          if (want['opened'] == 'true') {
            nativePrompt = ProtectionOwnTagSosPrompt(
              terminal: want['kind'] ?? 'cancel',
              deadlineAt: base.add(
                Duration(milliseconds: int.parse(event[0]) + 30000),
              ),
            );
          } else if (want['prompt'] == 'closed' || want['armed'] == 'false') {
            nativePrompt = null;
          }
          if (event[1] == 'answer' && args['choice'] != 'timeout') {
            nativeAnswer = expected;
            final outcome = await tracker!.answer(
              args['choice'] == 'stopTag'
                  ? AmbiguousTagSosChoice.stopTag
                  : AmbiguousTagSosChoice.sendSos,
            );
            expect(outcome, switch (expected) {
              'sosOpened' => AmbiguousTagSosAnswerOutcome.sosSent,
              'stop' => AmbiguousTagSosAnswerOutcome.tagStopped,
              _ => AmbiguousTagSosAnswerOutcome.noPrompt,
            }, reason: '$label: answer outcome');
          } else if (shownBefore != nativePrompt) {
            await tracker!.refresh(nativePrompt == null ? 'closed' : 'opened');
          }
          if (want.containsKey('prompt') || want.containsKey('opened')) {
            promptSteps++;
            final shown = tracker!.current;
            expect(
              shown == null ? 'closed' : 'open',
              want['prompt'] ?? (want['opened'] == 'true' ? 'open' : 'closed'),
              reason: '$label: prompt shown to the host',
            );
            if (want['kind'] != null && shown != null) {
              expect(shown.terminal.name, want['kind'], reason: label);
            }
          }
          if (args['source'] != 'dart') {
            continue; // native-path frames never reach Dart's BLE link
          }
          // Fixture node 7 is the connected TAG; any other node is another TAG.
          final own = (args['node'] ?? '7') == '7';
          final node = own ? ownNode : 0x0063;
          switch (event[1]) {
            case 'frame':
              final verdict = switch (expected) {
                'pass' => OwnTagSosFrameVerdict.proceed,
                'newSos' => OwnTagSosFrameVerdict.newSos,
                _ => OwnTagSosFrameVerdict.suppress,
              };
              final before = forwarded.length;
              final handledBefore = controller!.startPacketsHandled;
              if (own) {
                expectedVerdicts.add(verdict);
              }
              final channel = dartFrames.isEven
                  ? EixamBleChannel.sos
                  : EixamBleChannel.tel;
              final payload = sosPush(node, ++variant);
              await deliver(channel, payload);
              dartFrames++;
              if (!own) {
                // Not an own-TAG frame: never forwarded, handled as before.
                expect(forwarded.length, before, reason: '$label: other TAG');
                expect(
                  verdict,
                  OwnTagSosFrameVerdict.proceed,
                  reason: '$label: native also lets another TAG pass',
                );
                break;
              }
              expect(forwarded.length, before + 1, reason: '$label: forwarded');
              expect(forwarded.last.bytes, payload, reason: label);
              expect(forwarded.last.isClose, isFalse, reason: label);
              expect(
                forwarded.last.characteristic,
                channel == EixamBleChannel.tel ? 'tel' : 'sos',
                reason: label,
              );
              expect(
                controller.startPacketsHandled - handledBefore,
                verdict == OwnTagSosFrameVerdict.suppress ? 0 : 1,
                reason: '$label: Dart acts only on ${verdict.name}',
              );
            case 'close':
              final before = forwarded.length;
              await deliver(
                EixamBleChannel.tel,
                closeFrame(
                  node,
                  opcode: switch (args['code']) {
                    'E2' => 0xE2,
                    'E3' => 0xE3,
                    _ => 0xE1,
                  },
                ),
              );
              if (own) {
                expect(
                  forwarded.length,
                  before + 1,
                  reason: '$label: forwarded',
                );
                expect(forwarded.last.isClose, isTrue, reason: label);
              } else {
                expect(forwarded.length, before, reason: '$label: other TAG');
              }
            case 'seen':
            case 'link_up':
            case 'link_drop':
              // Dart link notes go from the SDK (not the provider) to native;
              // covered by the SDK matrix test, classified by the native replays.
              break;
            default:
              fail('$label: unexpected Dart-path event');
          }
          expect(expectedVerdicts, isEmpty, reason: '$label: verdict consumed');
        }
      } finally {
        await closeScenario();
        await tracker?.dispose();
      }
      expect(
        promptSteps,
        greaterThanOrEqualTo(60),
        reason: 'prompt steps replayed',
      );
      expect(scenarios, greaterThan(25));
      expect(dartFrames, greaterThan(30));
      // Every fixture scenario replays a real BLE provider: > 30 s in all.
    }, timeout: const Timeout(Duration(minutes: 3)));

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
