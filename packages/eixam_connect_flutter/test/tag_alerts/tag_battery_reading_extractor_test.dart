import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/tag_battery_reading_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tag_battery_test_support.dart';

void main() {
  final now = DateTime.utc(2026, 11, 2, 12);
  final status = connectedTag();

  TagBatteryReading? extract(BleIncomingEvent event, {DeviceStatus? s}) =>
      TagBatteryReadingExtractor.fromEvent(event, status: s ?? status);

  LiveRecord record(DateTime at, int level, {int packetId = 1, int? node}) => (
    timestamp: unixOf(at),
    wire: telWire(level: level, packetId: packetId, nodeId: node ?? tagNodeId),
  );

  group('0xD3 live batch', () {
    test('uses the newest timestamped sample, mapped to four bands', () {
      for (final entry in {
        0: TagBatteryBand.below10,
        1: TagBatteryBand.below30,
        2: TagBatteryBand.medium,
        3: TagBatteryBand.ok,
      }.entries) {
        final reading = extract(
          liveBatchEvent(now, [
            record(now.subtract(const Duration(seconds: 50)), 3, packetId: 1),
            record(
              now.subtract(const Duration(seconds: 5)),
              entry.key,
              packetId: 2,
            ),
            record(now.subtract(const Duration(seconds: 30)), 3, packetId: 3),
          ]),
        );
        expect(reading!.band, entry.value, reason: '${entry.key}');
      }
    });

    test('the source key identifies the sample, not the delivery', () {
      final at = now.subtract(const Duration(seconds: 5));
      final a = extract(liveBatchEvent(now, [record(at, 1)]))!;
      final again = extract(liveBatchEvent(now, [record(at, 1)]))!;
      final next = extract(
        liveBatchEvent(now, [
          record(now.subtract(const Duration(seconds: 1)), 1, packetId: 2),
        ]),
      )!;
      expect(again.sourceKey, a.sourceKey);
      expect(next.sourceKey, isNot(a.sourceKey));
    });

    test('freshness window is [-2 min, +3 min]', () {
      TagBatteryReading? at(Duration age) =>
          extract(liveBatchEvent(now, [record(now.subtract(age), 1)]));
      expect(at(const Duration(minutes: 3)), isNotNull);
      expect(at(const Duration(minutes: 3, seconds: 1)), isNull);
      expect(at(const Duration(hours: 6)), isNull);
      expect(at(const Duration(minutes: -2)), isNotNull);
      expect(at(const Duration(minutes: -2, seconds: -1)), isNull);
    });

    test('fails closed without a plausible device timestamp', () {
      expect(
        extract(liveBatchEvent(now, [(timestamp: 0, wire: telWire(level: 1))])),
        isNull,
      );
      // Boot-relative counter: far in the past, nulled by the batch parser.
      expect(
        extract(
          liveBatchEvent(now, [(timestamp: 5000, wire: telWire(level: 1))]),
        ),
        isNull,
      );
    });

    test('a late flush with old samples is never a reading', () {
      final old = now.subtract(const Duration(minutes: 40));
      expect(
        extract(
          liveBatchEvent(now, [
            record(old, 0, packetId: 1),
            record(old.add(const Duration(minutes: 1)), 0, packetId: 2),
          ]),
        ),
        isNull,
      );
    });

    test('rejects a batch containing another node', () {
      final at = now.subtract(const Duration(seconds: 5));
      expect(
        extract(
          liveBatchEvent(now, [
            record(at, 1),
            record(at, 1, packetId: 2, node: 0x0BADF00D),
          ]),
        ),
        isNull,
      );
    });

    test('needs a connected, paired TAG with a known node', () {
      final at = now.subtract(const Duration(seconds: 5));
      final event = liveBatchEvent(now, [record(at, 1)]);
      expect(extract(event, s: connectedTag(connected: false)), isNull);
      expect(extract(event, s: connectedTag(paired: false)), isNull);
      expect(extract(event, s: connectedTag(nodeId: null)), isNull);
      expect(extract(event, s: connectedTag(nodeId: 7)), isNull);
      expect(TagBatteryReadingExtractor.fromEvent(event, status: null), isNull);
    });
  });

  group('classic TEL', () {
    test('own node maps the 2-bit level; another node is rejected', () {
      expect(
        extract(classicTelEvent(now, telWire(level: 0)))!.band,
        TagBatteryBand.below10,
      );
      expect(
        extract(classicTelEvent(now, telWire(level: 1, nodeId: 99))),
        isNull,
      );
      expect(
        extract(
          classicTelEvent(now, telWire(level: 1)),
          s: connectedTag(connected: false),
        ),
        isNull,
      );
    });
  });

  group('0x23 GET_DEVICE_STATUS', () {
    test('maps the percentage to the same four bands', () {
      for (final entry in {
        100: TagBatteryBand.ok,
        60: TagBatteryBand.ok,
        59: TagBatteryBand.medium,
        30: TagBatteryBand.medium,
        29: TagBatteryBand.below30,
        10: TagBatteryBand.below30,
        9: TagBatteryBand.below10,
        1: TagBatteryBand.below10,
      }.entries) {
        expect(
          extract(runtimeStatusEvent(now, percent: entry.key))!.band,
          entry.value,
          reason: '${entry.key}',
        );
      }
    });

    test('ignores 0 (no battery) and the 0xFF sentinel (null)', () {
      expect(extract(runtimeStatusEvent(now, percent: 0)), isNull);
      expect(extract(runtimeStatusEvent(now, percent: null)), isNull);
      expect(extract(runtimeStatusEvent(now, percent: 255)), isNull);
    });

    test('counts during the connect-time hydrate and checks the node', () {
      // The public status may not be connected / know the node yet.
      expect(
        extract(
          runtimeStatusEvent(now, percent: 20),
          s: connectedTag(connected: false, nodeId: null),
        ),
        isNotNull,
      );
      expect(
        extract(runtimeStatusEvent(now, nodeId: 99), s: connectedTag()),
        isNull,
      );
      expect(
        extract(runtimeStatusEvent(now), s: connectedTag(paired: false)),
        isNull,
      );
    });

    test('the same reply is one source whether seen as event or return', () {
      final fromEvent = extract(runtimeStatusEvent(now, percent: 20))!;
      final fromReturn = TagBatteryReadingExtractor.fromRuntimeStatus(
        runtimeStatus(percent: 20, receivedAt: now),
        status: status,
      )!;
      expect(fromReturn.sourceKey, fromEvent.sourceKey);
      expect(
        TagBatteryReadingExtractor.fromRuntimeStatus(
          runtimeStatus(percent: 20, omitReceivedAt: true),
          status: status,
        ),
        isNull,
      );
    });
  });

  test('historical, relayed, SOS and other traffic is never a reading', () {
    for (final type in BleIncomingEventType.values) {
      if (type == BleIncomingEventType.telLivePositionBatch ||
          type == BleIncomingEventType.telPosition ||
          type == BleIncomingEventType.deviceRuntimeStatus) {
        continue;
      }
      expect(extract(eventOfType(type, now)), isNull, reason: '$type');
    }
  });
}
