import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/tag_last_position_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tag_battery_test_support.dart';

void main() {
  final now = DateTime.utc(2026, 11, 2, 12);
  final status = connectedTag();

  LiveRecord record(DateTime at, {int packetId = 1, int? node}) => (
    timestamp: unixOf(at),
    wire: telWire(level: 3, packetId: packetId, nodeId: node ?? tagNodeId),
  );

  TagAlertPosition? extract(BleIncomingEvent e, {DeviceStatus? s}) =>
      TagLastPositionExtractor.fromEvent(e, status: s ?? status);

  test('uses the newest timestamped live sample of the connected TAG', () {
    final newest = now.subtract(const Duration(seconds: 5));
    final position = extract(
      liveBatchEvent(now, [
        record(now.subtract(const Duration(seconds: 60)), packetId: 1),
        record(newest, packetId: 2),
        record(now.subtract(const Duration(seconds: 30)), packetId: 3),
      ]),
    )!;
    expect(position.source, SdkLocationSource.connectedDevice);
    expect(position.timestamp, newest);
  });

  test('a classic own TEL packet is stamped with its receive time', () {
    final position = extract(classicTelEvent(now, telWire(level: 3)))!;
    expect(position.timestamp, now);
    expect(position.source, SdkLocationSource.connectedDevice);
  });

  test('never another TAG, another device, or a disconnected link', () {
    final at = now.subtract(const Duration(seconds: 5));
    expect(extract(liveBatchEvent(now, [record(at, node: 99)])), isNull);
    expect(
      extract(liveBatchEvent(now, [record(at)], deviceId: 'other')),
      isNull,
    );
    expect(
      extract(
        liveBatchEvent(now, [record(at)]),
        s: connectedTag(connected: false),
      ),
      isNull,
    );
    expect(
      extract(liveBatchEvent(now, [record(at)]), s: connectedTag(nodeId: null)),
      isNull,
    );
    expect(
      extract(classicTelEvent(now, telWire(level: 3, nodeId: 99))),
      isNull,
    );
  });

  test('samples without a plausible device time give no position', () {
    expect(
      extract(liveBatchEvent(now, [(timestamp: 0, wire: telWire(level: 3))])),
      isNull,
    );
  });

  test('other traffic never yields a position', () {
    for (final type in BleIncomingEventType.values) {
      if (type == BleIncomingEventType.telLivePositionBatch ||
          type == BleIncomingEventType.telPosition) {
        continue;
      }
      expect(extract(eventOfType(type, now)), isNull, reason: '$type');
    }
    expect(
      TagLastPositionExtractor.fromEvent(
        eventOfType(BleIncomingEventType.telPosition, now),
        status: null,
      ),
      isNull,
    );
  });
}
