import '../enums/device_country_config_outcome.dart';
import '../enums/lora_region_code.dart';

/// Typed public state describing the most recent per-country radio-config apply.
///
/// Hosts observe this for control flow; the same snapshot is also threaded into
/// `SdkOperationalDiagnostics` for support tooling.
class DeviceCountryConfigStatus {
  const DeviceCountryConfigStatus({
    required this.outcome,
    required this.updatedAt,
    this.countryIso,
    this.targetRegion,
    this.deviceReportedRegion,
    this.deviceConfig,
    this.detail,
  });

  factory DeviceCountryConfigStatus.idle() {
    return DeviceCountryConfigStatus(
      outcome: DeviceCountryConfigOutcome.idle,
      updatedAt: DateTime.now(),
    );
  }

  final DeviceCountryConfigOutcome outcome;
  final DateTime updatedAt;

  /// ISO country resolved for the device's physical location.
  final String? countryIso;

  /// Region the SDK intended to apply (from the backend `device_config`).
  final LoraRegionCode? targetRegion;

  /// Region the device reported via the status packet (`0x23`).
  final LoraRegionCode? deviceReportedRegion;

  /// Backend `device_config` spec string the target was derived from.
  final String? deviceConfig;

  /// Human-readable note for diagnostics (e.g. why an apply was skipped).
  final String? detail;

  bool get isApplied => outcome == DeviceCountryConfigOutcome.applied;

  /// A region change is actively in progress — the host should show loading.
  bool get isApplying => outcome == DeviceCountryConfigOutcome.applying;

  /// Final state (neither [DeviceCountryConfigOutcome.idle] nor
  /// [DeviceCountryConfigOutcome.applying]) — safe to resolve a loading modal.
  bool get isTerminal =>
      outcome != DeviceCountryConfigOutcome.idle &&
      outcome != DeviceCountryConfigOutcome.applying;

  /// An attempted apply did not succeed — the host should show an error. Covers
  /// a hard [DeviceCountryConfigOutcome.failed] and the soft
  /// [DeviceCountryConfigOutcome.skippedFirmwareUnsupported] (firmware lacks the
  /// region command). The other `skipped*` outcomes never emit [isApplying]
  /// first, so they stay transparent (no modal).
  bool get isFailure =>
      outcome == DeviceCountryConfigOutcome.failed ||
      outcome == DeviceCountryConfigOutcome.skippedFirmwareUnsupported;

  DeviceCountryConfigStatus copyWith({
    DeviceCountryConfigOutcome? outcome,
    DateTime? updatedAt,
    Object? countryIso = _unset,
    Object? targetRegion = _unset,
    Object? deviceReportedRegion = _unset,
    Object? deviceConfig = _unset,
    Object? detail = _unset,
  }) {
    return DeviceCountryConfigStatus(
      outcome: outcome ?? this.outcome,
      updatedAt: updatedAt ?? this.updatedAt,
      countryIso: identical(countryIso, _unset)
          ? this.countryIso
          : countryIso as String?,
      targetRegion: identical(targetRegion, _unset)
          ? this.targetRegion
          : targetRegion as LoraRegionCode?,
      deviceReportedRegion: identical(deviceReportedRegion, _unset)
          ? this.deviceReportedRegion
          : deviceReportedRegion as LoraRegionCode?,
      deviceConfig: identical(deviceConfig, _unset)
          ? this.deviceConfig
          : deviceConfig as String?,
      detail: identical(detail, _unset) ? this.detail : detail as String?,
    );
  }

  static const Object _unset = Object();
}
