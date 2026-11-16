/// Display-only classification of a BLE discovery result for a TAG pairing
/// list.
///
/// This decides what a host may *show* and how to label or sort it. It never
/// authorizes a connection: identity, compatibility and readiness are still
/// established by the SDK connection paths after the user selects a device.
enum EixamPairingDisplayCategory {
  /// Eixam firmware (Eixam service advertised, or a historical Eixam name).
  eixam,

  /// Stock Meshtastic firmware or an older unprovisioned Eixam TAG that only
  /// advertises the stock service.
  legacyOrStock,

  /// A device sitting in the DFU bootloader that needs firmware recovery.
  dfuRecovery,

  /// Not relevant for TAG pairing (unrelated peripherals, Eixam gateways).
  hidden,
}

/// Eixam TAG service UUID (`ea00`), advertised in the primary packet.
const String eixamPairingDisplayEixamServiceUuid =
    '6ba1b218-15a8-461f-9fa8-5dcae273ea00';

/// Stock Meshtastic service UUID (`eafd`).
const String eixamPairingDisplayStockServiceUuid =
    '6ba1b218-15a8-461f-9fa8-5dcae273eafd';

/// Whether [name] is an Eixam gateway name (`EIXAM_GW_…`).
bool isEixamGatewayName(String? name) =>
    _normalize(name).startsWith('eixam_gw_');

/// Classifies one discovery result for display.
///
/// Rules (names compared trimmed and case-insensitively):
/// 1. `EIXAM_GW_*` names are hidden (gateways are never paired as a TAG).
/// 2. A DFU service ([dfuServiceAdvertised]) or the name `AdaDFU` is
///    [EixamPairingDisplayCategory.dfuRecovery].
/// 3. The Eixam service UUID or a name starting with `EIXAM_` or matching `N6` + six hex digits is
///    [EixamPairingDisplayCategory.eixam].
/// 4. The stock service UUID or a name starting with `Meshtastic_` is
///    [EixamPairingDisplayCategory.legacyOrStock].
/// 5. Anything else is [EixamPairingDisplayCategory.hidden].
EixamPairingDisplayCategory classifyEixamPairingDisplay({
  String? name,
  Iterable<String> advertisedServiceUuids = const <String>[],
  bool dfuServiceAdvertised = false,
}) {
  final normalizedName = _normalize(name);
  if (normalizedName.startsWith('eixam_gw_')) {
    return EixamPairingDisplayCategory.hidden;
  }
  if (dfuServiceAdvertised || normalizedName == 'adadfu') {
    return EixamPairingDisplayCategory.dfuRecovery;
  }
  final uuids = advertisedServiceUuids.map(_normalize).toSet();
  if (uuids.contains(eixamPairingDisplayEixamServiceUuid) ||
      normalizedName.startsWith('eixam_') ||
      _tagSerialName.hasMatch(normalizedName)) {
    return EixamPairingDisplayCategory.eixam;
  }
  if (uuids.contains(eixamPairingDisplayStockServiceUuid) ||
      normalizedName.startsWith('meshtastic_')) {
    return EixamPairingDisplayCategory.legacyOrStock;
  }
  return EixamPairingDisplayCategory.hidden;
}

/// Keeps a device visible once it has been shown, so a later poll that lacks
/// the name (e.g. an iOS scan response that has not arrived) does not make it
/// flicker out of the list.
///
/// Only missing evidence is bridged: an explicit gateway name still hides the
/// device. Display-only; never authorizes a connection.
final class EixamPairingDisplayFilter {
  final Map<String, EixamPairingDisplayCategory> _shown =
      <String, EixamPairingDisplayCategory>{};

  /// Resolves the category to display for [deviceId] given the [fresh]
  /// classification of the latest result.
  EixamPairingDisplayCategory resolve({
    required String deviceId,
    required EixamPairingDisplayCategory fresh,
    String? name,
  }) {
    if (fresh != EixamPairingDisplayCategory.hidden) {
      _shown[deviceId] = fresh;
      return fresh;
    }
    if (isEixamGatewayName(name)) {
      _shown.remove(deviceId);
      return EixamPairingDisplayCategory.hidden;
    }
    return _shown[deviceId] ?? EixamPairingDisplayCategory.hidden;
  }

  /// Forgets every previously shown device.
  void reset() => _shown.clear();
}

/// Historical 2.7.63 TAG name: `N6` + exactly six hex digits.
final RegExp _tagSerialName = RegExp(r'^n6[0-9a-f]{6}$');

String _normalize(String? value) => (value ?? '').trim().toLowerCase();
