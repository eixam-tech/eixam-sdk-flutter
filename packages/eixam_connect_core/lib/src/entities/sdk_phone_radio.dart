import 'sdk_telemetry_payload.dart';

/// Android [TelephonyManager] data-network constants the mapper understands.
abstract final class AndroidNetworkType {
  static const int unknown = 0;
  static const int gprs = 1;
  static const int edge = 2;
  static const int umts = 3;
  static const int cdma = 4;
  static const int evdo0 = 5;
  static const int evdoA = 6;
  static const int oneXrtt = 7;
  static const int hsdpa = 8;
  static const int hsupa = 9;
  static const int hspa = 10;
  static const int iden = 11;
  static const int evdoB = 12;
  static const int lte = 13;
  static const int ehrpd = 14;
  static const int hspap = 15;
  static const int gsm = 16;
  static const int tdScdma = 17;
  static const int iwlan = 18;
  static const int lteCa = 19;
  static const int nr = 20;
}

/// Android [TelephonyDisplayInfo] override constants.
abstract final class AndroidOverrideNetworkType {
  static const int none = 0;
  static const int lteCa = 1;
  static const int lteAdvancedPro = 2;
  static const int nrNsa = 3;
  static const int nrNsaMmwave = 4;
  static const int nrAdvanced = 5;
}

/// Raw platform reading. Native code does not choose the coverage generation.
class SdkPhoneRadioReading {
  const SdkPhoneRadioReading({
    this.networkType,
    this.overrideNetworkType,
    this.radioAccessTechnology,
    this.cellularDataConnected,
  });

  factory SdkPhoneRadioReading.fromJson(Map<dynamic, dynamic> json) {
    return SdkPhoneRadioReading(
      networkType: _asInt(json['networkType']),
      overrideNetworkType: _asInt(json['overrideNetworkType']),
      radioAccessTechnology: _asString(json['radioAccessTechnology']),
      cellularDataConnected: _asBool(json['cellularDataConnected']),
    );
  }

  /// Android data-network type, when the platform reported one.
  final int? networkType;

  /// Android display override, when the platform reported one.
  final int? overrideNetworkType;

  /// iOS `CTRadioAccessTechnology*` string.
  final String? radioAccessTechnology;

  /// True when the default data path is cellular.
  final bool? cellularDataConnected;

  static SdkPhoneRadioReading? tryParse(Object? value) {
    if (value is! Map) {
      return null;
    }
    return SdkPhoneRadioReading.fromJson(value);
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }

  static String? _asString(Object? value) {
    if (value is! String) {
      return null;
    }
    return value;
  }

  static bool? _asBool(Object? value) {
    if (value is bool) {
      return value;
    }
    return null;
  }
}

/// Phone GPS identities that may carry a coverage sample.
bool sdkPhoneRadioApplies(String? identitySource) {
  switch (identitySource?.trim()) {
    case 'app':
    case 'native_background':
      return true;
    default:
      return false;
  }
}

/// True when this fix still needs a live radio read.
///
/// [fixIdentitySource] is the identity before backend device-id normalization.
/// That step rewrites a phone fix to `ble_node` when a tag is paired.
bool shouldProbePhoneRadio({
  required String? fixIdentitySource,
  required SdkTelemetryPayload payload,
}) {
  return sdkPhoneRadioApplies(fixIdentitySource) &&
      payload.radio == null &&
      !payload.phoneRadioSampled;
}

/// Maps one raw reading onto the coverage `radio` object.
/// A wifi RAT, IWLAN with no cellular override, and an empty reading return null.
SdkRadioSnapshot? mapPhoneRadio(SdkPhoneRadioReading reading) {
  if (_isNonCellularAccess(reading)) {
    return null;
  }
  final mapped =
      _mapAndroid(reading.networkType, reading.overrideNetworkType) ??
      _mapRadioAccess(reading.radioAccessTechnology);
  if (mapped == null) {
    return null;
  }
  return SdkRadioSnapshot(
    generation: mapped.generation,
    fiveGMode: mapped.fiveGMode,
    connected: reading.cellularDataConnected,
  );
}

/// Keeps a snapshotted phone radio, fills one from [probed], or clears radio
/// when the fix is not the phone.
SdkTelemetryPayload resolvePhoneRadio({
  required SdkTelemetryPayload payload,
  required String? fixIdentitySource,
  SdkPhoneRadioReading? probed,
}) {
  if (!sdkPhoneRadioApplies(fixIdentitySource)) {
    if (payload.radio == null) {
      return payload;
    }
    return payload.copyWith(radio: null);
  }
  if (payload.radio != null || payload.phoneRadioSampled) {
    return payload;
  }
  final radio = probed == null ? null : mapPhoneRadio(probed);
  if (radio == null) {
    return payload;
  }
  return payload.copyWith(radio: radio);
}

bool _isNonCellularAccess(SdkPhoneRadioReading reading) {
  switch (reading.radioAccessTechnology?.trim().toLowerCase()) {
    case 'wifi':
    case 'wlan':
      return true;
    default:
      return false;
  }
}

class _MappedGeneration {
  const _MappedGeneration(this.generation, [this.fiveGMode]);

  final String generation;
  final String? fiveGMode;
}

_MappedGeneration? _mapAndroid(int? networkType, int? overrideNetworkType) {
  if (networkType == null && overrideNetworkType == null) {
    return null;
  }
  final network = networkType == AndroidNetworkType.iwlan
      ? AndroidNetworkType.unknown
      : networkType ?? AndroidNetworkType.unknown;
  final override = overrideNetworkType ?? AndroidOverrideNetworkType.none;
  if (override == AndroidOverrideNetworkType.nrNsa ||
      override == AndroidOverrideNetworkType.nrNsaMmwave) {
    return const _MappedGeneration('5g', 'nsa');
  }
  if (override == AndroidOverrideNetworkType.nrAdvanced) {
    if (network == AndroidNetworkType.nr) {
      return const _MappedGeneration('5g', 'sa');
    }
    return const _MappedGeneration('5g');
  }
  if (network == AndroidNetworkType.nr) {
    return const _MappedGeneration('5g', 'sa');
  }
  if (network == AndroidNetworkType.unknown &&
      override == AndroidOverrideNetworkType.none) {
    return null;
  }
  if (network == AndroidNetworkType.lte ||
      network == AndroidNetworkType.lteCa ||
      override == AndroidOverrideNetworkType.lteCa ||
      override == AndroidOverrideNetworkType.lteAdvancedPro) {
    return const _MappedGeneration('4g');
  }
  if (_is3g(network)) {
    return const _MappedGeneration('3g');
  }
  if (_is2g(network)) {
    return const _MappedGeneration('2g');
  }
  return null;
}

bool _is3g(int network) {
  switch (network) {
    case AndroidNetworkType.umts:
    case AndroidNetworkType.evdo0:
    case AndroidNetworkType.evdoA:
    case AndroidNetworkType.hsdpa:
    case AndroidNetworkType.hsupa:
    case AndroidNetworkType.hspa:
    case AndroidNetworkType.evdoB:
    case AndroidNetworkType.ehrpd:
    case AndroidNetworkType.hspap:
    case AndroidNetworkType.tdScdma:
      return true;
    default:
      return false;
  }
}

bool _is2g(int network) {
  switch (network) {
    case AndroidNetworkType.gprs:
    case AndroidNetworkType.edge:
    case AndroidNetworkType.cdma:
    case AndroidNetworkType.oneXrtt:
    case AndroidNetworkType.iden:
    case AndroidNetworkType.gsm:
      return true;
    default:
      return false;
  }
}

_MappedGeneration? _mapRadioAccess(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) {
    return null;
  }
  switch (value) {
    case 'CTRadioAccessTechnologyNRNSA':
    case 'NRNSA':
      return const _MappedGeneration('5g', 'nsa');
    case 'CTRadioAccessTechnologyNR':
    case 'NR':
      return const _MappedGeneration('5g', 'sa');
    case 'CTRadioAccessTechnologyLTE':
    case 'LTE':
      return const _MappedGeneration('4g');
    case 'CTRadioAccessTechnologyWCDMA':
    case 'CTRadioAccessTechnologyHSDPA':
    case 'CTRadioAccessTechnologyHSUPA':
    case 'CTRadioAccessTechnologyCDMAEVDORev0':
    case 'CTRadioAccessTechnologyCDMAEVDORevA':
    case 'CTRadioAccessTechnologyCDMAEVDORevB':
    case 'CTRadioAccessTechnologyeHRPD':
    case 'WCDMA':
    case 'HSDPA':
    case 'HSUPA':
      return const _MappedGeneration('3g');
    case 'CTRadioAccessTechnologyGPRS':
    case 'CTRadioAccessTechnologyEdge':
    case 'CTRadioAccessTechnologyCDMA1x':
    case 'GPRS':
    case 'EDGE':
      return const _MappedGeneration('2g');
    default:
      return null;
  }
}
