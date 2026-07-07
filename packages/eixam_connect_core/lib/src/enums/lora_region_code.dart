/// Meshtastic LoRa `RegionCode` byte the firmware applies when the SDK pushes a
/// per-country radio config over BLE (CMD opcode `0x20`).
///
/// Wire values mirror `meshtastic_Config_LoRaConfig_RegionCode` in the firmware
/// (`mesh/generated/meshtastic/config.pb.h`). This enum is only a **label** for
/// a region byte — the byte the SDK applies comes from the backend
/// (`device_configs.lora_region_code`), NOT from any in-SDK country/spec
/// mapping. Use [fromWireValue] to label a byte for diagnostics; an unmodeled
/// byte resolves to [unset]. [eu868] is the safe fallback region.
enum LoraRegionCode {
  unset(0),
  us915(1),
  eu433(2),
  eu868(3),
  cn470(4),
  as923jp(5),
  au915(6),
  kr920(7),
  tw(8),
  ru864(9),
  in865(10),
  nz865(11),
  as923(12),
  ua868(15),
  my919(17),
  sg923(18),
  ph915(21),
  kz863(24),
  np865(25),
  br902(26);

  const LoraRegionCode(this.wireValue);

  /// Byte written to the device CMD characteristic as the `0x20` payload, and
  /// the value reported back by the device status packet (`0x23`, byte 3).
  final int wireValue;

  /// Whether this region can actually be applied to a device (not [unset]).
  bool get isApplicable => this != LoraRegionCode.unset;

  /// Interprets a region wire byte (backend `lora_region_code` or status
  /// `0x23`) as a typed label. An unmodeled byte resolves to [unset]; callers
  /// that drive the apply/idempotency logic compare the raw byte numerically.
  static LoraRegionCode fromWireValue(int wireValue) {
    for (final region in LoraRegionCode.values) {
      if (region.wireValue == wireValue) {
        return region;
      }
    }
    return LoraRegionCode.unset;
  }
}
