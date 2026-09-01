import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'ble_incoming_event.dart';
import 'eixam_sos_packet.dart';
import 'eixam_tel_packet.dart';

/// Last valid fix per `nodeId`. A 7 B `sosType = 3` or a 12 B Null Island
/// frame must keep the previous pin, with that sample's timestamp as age.
class EixamLastKnownPositionStore {
  final Map<int, TrackingPosition> _byNodeId = <int, TrackingPosition>{};

  TrackingPosition? lookup(int nodeId) => _byNodeId[nodeId];

  void remember(int nodeId, TrackingPosition? position) {
    if (position == null || !position.hasValidFix) {
      return;
    }
    _byNodeId[nodeId] = position;
  }

  void rememberTel(EixamTelPacket packet, DateTime receivedAt) {
    remember(
      packet.nodeId,
      TrackingPosition(
        latitude: packet.position.latitude,
        longitude: packet.position.longitude,
        altitude: packet.position.altitudeMeters.toDouble(),
        timestamp: receivedAt,
        source: DeliveryMode.mesh,
      ),
    );
  }

  void rememberSos(EixamSosPacket packet, DateTime receivedAt) {
    remember(packet.nodeId, packet.trackingPositionAt(receivedAt));
  }

  BleIncomingPayloadClassification bind(
    BleIncomingPayloadClassification classification, {
    required DateTime receivedAt,
  }) {
    final telPacket = classification.telPacket;
    if (telPacket != null) {
      rememberTel(telPacket, receivedAt);
    }
    final sosPacket = classification.sosPacket;
    if (sosPacket == null) {
      return classification;
    }
    rememberSos(sosPacket, receivedAt);
    final snapshot = classification.remoteRelaySosSnapshot;
    if (snapshot == null || snapshot.kind != RemoteRelaySosKind.sos) {
      return classification;
    }
    if (snapshot.location != null && snapshot.location!.hasValidFix) {
      return classification;
    }
    final lastKnown = lookup(sosPacket.nodeId);
    return BleIncomingPayloadClassification(
      kind: classification.kind,
      sosPacket: sosPacket,
      sosEventPacket: classification.sosEventPacket,
      telPacket: classification.telPacket,
      remoteRelaySosSnapshot: RemoteRelaySosSnapshot(
        kind: snapshot.kind,
        originatorNodeId: snapshot.originatorNodeId,
        relayNodeId: snapshot.relayNodeId,
        source: snapshot.source,
        sosType: snapshot.sosType,
        location: lastKnown,
        receivedAt: snapshot.receivedAt,
        rawPayload: snapshot.rawPayload,
        payloadHex: snapshot.payloadHex,
        relayCount: snapshot.relayCount,
        eventOpcode: snapshot.eventOpcode,
        eventSubcode: snapshot.eventSubcode,
      ),
    );
  }
}
