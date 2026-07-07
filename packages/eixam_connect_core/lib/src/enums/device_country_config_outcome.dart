/// Outcome — or in-progress state — of a device per-country radio-config apply
/// attempt, surfaced as typed public state via `DeviceCountryConfigStatus`.
enum DeviceCountryConfigOutcome {
  /// No check has run yet this session.
  idle,

  /// A region change is actively in progress (write + reboot + verify).
  /// NON-TERMINAL: always followed by [applied], [failed] or
  /// [skippedFirmwareUnsupported]. Emitted only when a real apply starts (never
  /// for the skip outcomes), so the host can show a loading modal.
  applying,

  /// A new region was written, the device rebooted, and the change verified.
  applied,

  /// The device already runs the target region; nothing was applied.
  skippedUpToDate,

  /// No usable device location was available to resolve a country.
  skippedNoLocation,

  /// Location resolved, but the country/config could not be determined (geo
  /// endpoint failure, 404/default config, or an unmapped `device_config`).
  skippedCountryUnknown,

  /// No command-capable device is connected.
  skippedDeviceOffline,

  /// An SOS / PreSOS / Death-Man / protection flow is active — a reboot would
  /// interrupt safety, so the apply is deferred.
  skippedSafetyActive,

  /// The device never adopted the region after reboot — its firmware likely
  /// does not implement the `0x20` region command yet.
  skippedFirmwareUnsupported,

  /// The apply was attempted but failed (write or verify error).
  failed,
}
