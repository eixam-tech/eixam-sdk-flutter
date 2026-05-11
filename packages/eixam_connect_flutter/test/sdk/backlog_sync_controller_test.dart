import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_backlog_sync_frame.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/sdk/backlog_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  group('BacklogSyncController', () {
    late StreamController<BleIncomingEvent> bleEvents;
    late FakeTelemetryRepository telemetryRepository;
    late List<EixamDeviceCommand> commands;

    setUp(() {
      bleEvents = StreamController<BleIncomingEvent>.broadcast();
      telemetryRepository = FakeTelemetryRepository();
      commands = <EixamDeviceCommand>[];
    });

    tearDown(() async {
      await bleEvents.close();
    });

    test('completes happy path and ACKs only after batch persistence',
        () async {
      final controller = BacklogSyncController(
        bleIncomingEvents: bleEvents.stream,
        telemetryRepository: telemetryRepository,
        commandSender: (command) async {
          commands.add(command);
          if (command.opcode == 0x30) {
            Future<void>.microtask(() {
              _emitFrame(
                bleEvents,
                _metaFrame(
                    sessionId: 7, totalEvents: 2, startOffset: 0, endOffset: 2),
              );
              _emitFrame(
                bleEvents,
                _chunkFrame(
                  sessionId: 7,
                  chunkOffset: 0,
                  records: const <_BacklogRecordSpec>[
                    _BacklogRecordSpec(timeUnix: 1710000000, wire10: _wire10A),
                    _BacklogRecordSpec(timeUnix: 1710000001, wire10: _wire10B),
                  ],
                ),
              );
            });
          } else if (command.opcode == 0x31) {
            Future<void>.microtask(() {
              _emitFrame(
                bleEvents,
                _endFrame(
                    sessionId: 7, sentEvents: 2, lastOffset: 2, status: 0),
              );
            });
          }
        },
        backendHardwareIdResolver: () async => 'CF:82:59:4B:1A:A8',
        sessionTimeout: const Duration(seconds: 1),
      );

      addTearDown(controller.dispose);

      await controller.start(maxEvents: 2);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(commands.map((command) => command.opcode), <int>[0x30, 0x31]);
      expect(commands.last.bytes, <int>[0x31, 0x07, 0x02, 0x00, 0x00, 0x00]);
      expect(telemetryRepository.publishCallCount, 2);
      expect(telemetryRepository.publishedPayloads, hasLength(2));
      expect(telemetryRepository.publishedPayloads.first.nodeId, 6824);
      expect(telemetryRepository.publishedPayloads.first.deviceId, '6824');
      expect(
        telemetryRepository.publishedPayloads.first.hardwareId,
        'CF:82:59:4B:1A:A8',
      );
      expect(
        telemetryRepository.publishedPayloads.first.eventId,
        '6824:1710000000:1',
      );
      expect(controller.currentState.phase, BacklogSyncPhase.completed);
      expect(controller.currentState.confirmedEvents, 2);
      expect(controller.currentState.nextOffset, 2);
    });

    test('does not ACK before backend persistence succeeds', () async {
      telemetryRepository.publishError = StateError('backend rejected chunk');
      final controller = BacklogSyncController(
        bleIncomingEvents: bleEvents.stream,
        telemetryRepository: telemetryRepository,
        commandSender: (command) async {
          commands.add(command);
          if (command.opcode == 0x30) {
            Future<void>.microtask(() {
              _emitFrame(
                bleEvents,
                _metaFrame(
                    sessionId: 3, totalEvents: 1, startOffset: 0, endOffset: 1),
              );
              _emitFrame(
                bleEvents,
                _chunkFrame(
                  sessionId: 3,
                  chunkOffset: 0,
                  records: const <_BacklogRecordSpec>[
                    _BacklogRecordSpec(timeUnix: 1710000000, wire10: _wire10A),
                  ],
                ),
              );
            });
          }
        },
        backendHardwareIdResolver: () async => 'device-42',
        sessionTimeout: const Duration(seconds: 1),
      );

      addTearDown(controller.dispose);

      await controller.start(maxEvents: 1);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(commands.map((command) => command.opcode), <int>[0x30]);
      expect(controller.currentState.phase, BacklogSyncPhase.failed);
      expect(controller.currentState.lastError,
          contains('backend rejected chunk'));
    });

    test('soft-aborts after timeout without traffic', () async {
      final controller = BacklogSyncController(
        bleIncomingEvents: bleEvents.stream,
        telemetryRepository: telemetryRepository,
        commandSender: (command) async {
          commands.add(command);
          if (command.opcode == 0x30) {
            Future<void>.microtask(() {
              _emitFrame(
                bleEvents,
                _metaFrame(
                    sessionId: 9, totalEvents: 3, startOffset: 0, endOffset: 3),
              );
            });
          }
        },
        backendHardwareIdResolver: () async => 'device-42',
        sessionTimeout: const Duration(milliseconds: 20),
      );

      addTearDown(controller.dispose);

      await controller.start(maxEvents: 3);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(commands.map((command) => command.opcode), <int>[0x30, 0x32]);
      expect(commands.last.bytes, <int>[0x32, 0x09, 0x02]);
      expect(controller.currentState.phase, BacklogSyncPhase.failed);
      expect(controller.currentState.lastError, contains('timed out'));
    });

    test('restarts with BACKLOG_SYNC_START after reconnect', () async {
      final controller = BacklogSyncController(
        bleIncomingEvents: bleEvents.stream,
        telemetryRepository: telemetryRepository,
        commandSender: (command) async {
          commands.add(command);
        },
        backendHardwareIdResolver: () async => 'device-42',
        sessionTimeout: const Duration(seconds: 1),
      );

      addTearDown(controller.dispose);

      await controller.start(
        since: DateTime.fromMillisecondsSinceEpoch(1710000000000, isUtc: true),
        maxEvents: 10,
      );
      _emitFrame(
        bleEvents,
        _metaFrame(
            sessionId: 4, totalEvents: 10, startOffset: 0, endOffset: 10),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await controller.onDeviceStatusChanged(
        previous: const DeviceStatus(
          deviceId: 'ble-demo-r1',
          paired: true,
          activated: true,
          connected: true,
        ),
        current: const DeviceStatus(
          deviceId: 'ble-demo-r1',
          paired: true,
          activated: true,
          connected: false,
        ),
      );
      await controller.onDeviceStatusChanged(
        previous: const DeviceStatus(
          deviceId: 'ble-demo-r1',
          paired: true,
          activated: true,
          connected: false,
        ),
        current: const DeviceStatus(
          deviceId: 'ble-demo-r1',
          paired: true,
          activated: true,
          connected: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(commands.map((command) => command.opcode), <int>[0x30, 0x30]);
      expect(commands.first.bytes, commands.last.bytes);
      expect(controller.currentState.phase, BacklogSyncPhase.starting);
    });
  });
}

void _emitFrame(
  StreamController<BleIncomingEvent> bleEvents,
  List<int> payload,
) {
  bleEvents.add(
    BleIncomingEvent(
      deviceId: 'ble-demo-r1',
      type: BleIncomingEventType.backlogSyncFrame,
      channel: EixamBleChannel.tel,
      payload: payload,
      payloadHex: EixamBleProtocol.hex(payload),
      source: DeviceSosTransitionSource.device,
      receivedAt: DateTime.now().toUtc(),
      backlogSyncFrame: EixamBacklogSyncFrame.tryParse(payload),
    ),
  );
}

List<int> _metaFrame({
  required int sessionId,
  required int totalEvents,
  required int startOffset,
  required int endOffset,
}) {
  return <int>[
    0xD1,
    0x01,
    sessionId,
    totalEvents & 0xFF,
    (totalEvents >> 8) & 0xFF,
    startOffset & 0xFF,
    (startOffset >> 8) & 0xFF,
    (startOffset >> 16) & 0xFF,
    (startOffset >> 24) & 0xFF,
    endOffset & 0xFF,
    (endOffset >> 8) & 0xFF,
    (endOffset >> 16) & 0xFF,
    (endOffset >> 24) & 0xFF,
  ];
}

List<int> _chunkFrame({
  required int sessionId,
  required int chunkOffset,
  required List<_BacklogRecordSpec> records,
}) {
  final bytes = <int>[
    0xD1,
    0x02,
    sessionId,
    chunkOffset & 0xFF,
    (chunkOffset >> 8) & 0xFF,
    (chunkOffset >> 16) & 0xFF,
    (chunkOffset >> 24) & 0xFF,
    records.length,
  ];
  for (final record in records) {
    bytes.addAll(<int>[
      record.timeUnix & 0xFF,
      (record.timeUnix >> 8) & 0xFF,
      (record.timeUnix >> 16) & 0xFF,
      (record.timeUnix >> 24) & 0xFF,
      ...record.wire10,
    ]);
  }
  return bytes;
}

List<int> _endFrame({
  required int sessionId,
  required int sentEvents,
  required int lastOffset,
  required int status,
}) {
  return <int>[
    0xD1,
    0x03,
    sessionId,
    sentEvents & 0xFF,
    (sentEvents >> 8) & 0xFF,
    lastOffset & 0xFF,
    (lastOffset >> 8) & 0xFF,
    (lastOffset >> 16) & 0xFF,
    (lastOffset >> 24) & 0xFF,
    status & 0xFF,
  ];
}

class _BacklogRecordSpec {
  const _BacklogRecordSpec({
    required this.timeUnix,
    required this.wire10,
  });

  final int timeUnix;
  final List<int> wire10;
}

const List<int> _wire10A = <int>[
  0xA8,
  0x1A,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  0x21,
  0x01,
  0x00,
];

const List<int> _wire10B = <int>[
  0xB0,
  0x1A,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  0x21,
  0x02,
  0x00,
];
