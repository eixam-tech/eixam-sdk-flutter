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
  timeout,
  disconnected,

  /// SDK-local: the native protection runtime owns the BLE link. It writes
  /// `0x40`/`0x41` but does not bridge TEL notifies (`0xD0`/`0xDA`/`E9 7A`)
  /// back to Dart, so no confirmation can arrive. Fail fast instead of
  /// waiting for [timeout]. Nearby is usable again once Flutter owns BLE.
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
      _ => null,
    };
  }

  bool get accepted => this == NearbyTextTxStatus.onAir;
}
