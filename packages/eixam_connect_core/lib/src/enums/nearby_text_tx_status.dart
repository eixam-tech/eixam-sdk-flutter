/// Firmware `0xDA` status byte plus SDK-local outcomes.
enum NearbyTextTxStatus {
  onAir,
  sos,
  rateLimited,
  psa,
  badUtf8,
  tooLong,
  notProvisioned,
  empty,
  badFrame,
  pkiNoKey,
  pkiFailed,
  unknownGroup,

  /// At least one node ACKed a plaza/group (or a non-dest node ACKed a DM).
  meshAck,

  /// The addressed PKI dest ACKed this packet.
  recipientAck,

  /// Reliable retries exhausted (`MAX_RETRANSMIT` / `TIMEOUT`).
  ackTimeout,

  /// Routing NAK other than timeout.
  gotNak,

  /// Unrecognized `0xDA` status byte. Still classified as Nearby, never SOS.
  unknown,

  timeout,
  disconnected,

  /// Legacy SDK-local status. Current native protection forwards TEL
  /// notifies to Dart, so Nearby no longer returns this before a write.
  bleOwnedByProtection;

  static NearbyTextTxStatus? fromWire(int status) {
    return switch (status) {
      0 => NearbyTextTxStatus.onAir,
      1 => NearbyTextTxStatus.sos,
      2 => NearbyTextTxStatus.rateLimited,
      3 => NearbyTextTxStatus.psa,
      4 => NearbyTextTxStatus.badUtf8,
      5 => NearbyTextTxStatus.tooLong,
      6 => NearbyTextTxStatus.notProvisioned,
      7 => NearbyTextTxStatus.empty,
      8 => NearbyTextTxStatus.badFrame,
      9 => NearbyTextTxStatus.pkiNoKey,
      10 => NearbyTextTxStatus.pkiFailed,
      11 => NearbyTextTxStatus.unknownGroup,
      12 => NearbyTextTxStatus.meshAck,
      13 => NearbyTextTxStatus.recipientAck,
      14 => NearbyTextTxStatus.ackTimeout,
      15 => NearbyTextTxStatus.gotNak,
      _ => NearbyTextTxStatus.unknown,
    };
  }

  bool get accepted => this == NearbyTextTxStatus.onAir;

  /// Follow-up `0xDA` after on-air. Does not complete the send waiter.
  bool get isDeliveryUpdate => switch (this) {
    NearbyTextTxStatus.meshAck ||
    NearbyTextTxStatus.recipientAck ||
    NearbyTextTxStatus.ackTimeout ||
    NearbyTextTxStatus.gotNak => true,
    _ => false,
  };

  bool get deliveryConfirmed =>
      this == NearbyTextTxStatus.meshAck ||
      this == NearbyTextTxStatus.recipientAck;
}
