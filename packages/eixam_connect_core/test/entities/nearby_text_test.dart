import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  test('isBroadcast is plaza only, not group traffic on broadcast dest', () {
    final group = NearbyIncomingText(
      fromNodeId: 1,
      packetId: 1,
      text: 'hi',
      receivedAt: DateTime.utc(2026, 1, 1),
      destNodeId: 0xFFFFFFFF,
      groupId: 9,
    );
    expect(group.isBroadcast, isFalse);
    expect(group.isGroup, isTrue);
    expect(group.isDirect, isFalse);

    final plaza = NearbyIncomingText(
      fromNodeId: 1,
      packetId: 1,
      text: 'hi',
      receivedAt: DateTime.utc(2026, 1, 1),
    );
    expect(plaza.isBroadcast, isTrue);
    expect(plaza.isDirect, isFalse);
    expect(plaza.isGroup, isFalse);
  });

  test('hardware fallback label is EIXAM_ plus 8 hex digits', () {
    expect(NearbyNodeName.hardwareLabel(0xAA), 'EIXAM_000000AA');
    expect(
      NearbyNodeName(
        nodeId: 0xAA,
        name: 'EIXAM_000000AA',
        receivedAt: DateTime.utc(2026, 1, 1),
      ).isHardwareFallback,
      isTrue,
    );
    expect(
      NearbyNodeName(
        nodeId: 0xAA,
        name: 'Alice',
        receivedAt: DateTime.utc(2026, 1, 1),
      ).isHardwareFallback,
      isFalse,
    );
  });

  test('max SECONDARY group slots match Meshtastic leftover indices', () {
    expect(NearbyGroupCommandResult.maxSecondarySlots, 7);
  });
}
