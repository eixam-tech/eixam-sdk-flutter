import 'dart:collection';

/// An independently active reason for requesting background location.
enum BackgroundLocationContext {
  sharing,
  dmp,
  sos,
}

/// The effective background-location behavior requested from a platform.
enum BackgroundLocationMode {
  idle,
  sharing,
  dmp,
  sos,
}

/// Resolves active contexts using the canonical `SOS > DMP > sharing` priority.
///
/// Removing one context never suppresses another context that remains active.
BackgroundLocationMode resolveBackgroundLocationMode(
  Iterable<BackgroundLocationContext> contexts,
) {
  var hasSharing = false;
  var hasDmp = false;

  for (final context in contexts) {
    switch (context) {
      case BackgroundLocationContext.sos:
        return BackgroundLocationMode.sos;
      case BackgroundLocationContext.dmp:
        hasDmp = true;
      case BackgroundLocationContext.sharing:
        hasSharing = true;
    }
  }

  if (hasDmp) {
    return BackgroundLocationMode.dmp;
  }
  if (hasSharing) {
    return BackgroundLocationMode.sharing;
  }
  return BackgroundLocationMode.idle;
}

/// The operating-system authorization granted for location access.
enum LocationAuthorizationStatus {
  notDetermined,
  denied,
  restricted,
  whenInUse,
  always,
}

/// The operating-system accuracy authorization for location access.
enum LocationAccuracyAuthorization {
  unknown,
  reduced,
  full,
}

/// Typed location-permission state used by background-location capabilities.
///
/// Readiness and prompt-attempt properties are derived so callers cannot
/// construct a snapshot containing contradictory permission state.
class LocationPermissionSnapshot {
  const LocationPermissionSnapshot({
    required this.locationServicesEnabled,
    required this.authorizationStatus,
    required this.accuracyAuthorization,
  });

  /// Whether system-wide location services are currently enabled.
  final bool locationServicesEnabled;

  final LocationAuthorizationStatus authorizationStatus;
  final LocationAccuracyAuthorization accuracyAuthorization;

  bool get isForegroundLocationUsable =>
      locationServicesEnabled &&
      (authorizationStatus == LocationAuthorizationStatus.whenInUse ||
          authorizationStatus == LocationAuthorizationStatus.always);

  bool get isBackgroundLocationUsable =>
      locationServicesEnabled &&
      authorizationStatus == LocationAuthorizationStatus.always;

  /// Whether attempting a native When-In-Use request is appropriate.
  ///
  /// The platform still decides whether it displays permission UI.
  bool get canAttemptWhenInUsePrompt =>
      locationServicesEnabled &&
      authorizationStatus == LocationAuthorizationStatus.notDetermined;

  /// Whether attempting a native Always upgrade is appropriate.
  ///
  /// The platform still decides whether it displays permission UI.
  bool get canAttemptAlwaysUpgrade =>
      locationServicesEnabled &&
      authorizationStatus == LocationAuthorizationStatus.whenInUse;

  /// Whether recovery requires the user to change system or app settings.
  bool get requiresSettingsRecovery =>
      !locationServicesEnabled ||
      authorizationStatus == LocationAuthorizationStatus.denied ||
      authorizationStatus == LocationAuthorizationStatus.restricted;

  LocationPermissionSnapshot copyWith({
    bool? locationServicesEnabled,
    LocationAuthorizationStatus? authorizationStatus,
    LocationAccuracyAuthorization? accuracyAuthorization,
  }) {
    return LocationPermissionSnapshot(
      locationServicesEnabled:
          locationServicesEnabled ?? this.locationServicesEnabled,
      authorizationStatus: authorizationStatus ?? this.authorizationStatus,
      accuracyAuthorization:
          accuracyAuthorization ?? this.accuracyAuthorization,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LocationPermissionSnapshot &&
            locationServicesEnabled == other.locationServicesEnabled &&
            authorizationStatus == other.authorizationStatus &&
            accuracyAuthorization == other.accuracyAuthorization;
  }

  @override
  int get hashCode => Object.hash(
        locationServicesEnabled,
        authorizationStatus,
        accuracyAuthorization,
      );
}

/// Immutable public state for an optional native background-location runtime.
class BackgroundLocationRuntimeStatus {
  BackgroundLocationRuntimeStatus({
    required Iterable<BackgroundLocationContext> activeContexts,
    required this.isNativePlatformSupported,
    required this.isNativeServiceRunning,
    required this.permission,
    this.lastAcceptedLocationAt,
    this.lastErrorCode,
    this.lastErrorMessage,
    this.wasRestoredAfterRelaunch = false,
  }) : activeContexts = UnmodifiableSetView<BackgroundLocationContext>(
          Set<BackgroundLocationContext>.of(activeContexts),
        );

  /// Independently requested contexts. The returned set cannot be mutated.
  final Set<BackgroundLocationContext> activeContexts;

  /// Effective mode derived exclusively through [resolveBackgroundLocationMode].
  BackgroundLocationMode get effectiveMode =>
      resolveBackgroundLocationMode(activeContexts);

  final bool isNativePlatformSupported;
  final bool isNativeServiceRunning;
  final LocationPermissionSnapshot permission;
  final DateTime? lastAcceptedLocationAt;
  final String? lastErrorCode;
  final String? lastErrorMessage;

  /// Whether this state was restored after a normal application relaunch.
  final bool wasRestoredAfterRelaunch;

  BackgroundLocationRuntimeStatus copyWith({
    Iterable<BackgroundLocationContext>? activeContexts,
    bool? isNativePlatformSupported,
    bool? isNativeServiceRunning,
    LocationPermissionSnapshot? permission,
    Object? lastAcceptedLocationAt = _unset,
    Object? lastErrorCode = _unset,
    Object? lastErrorMessage = _unset,
    bool? wasRestoredAfterRelaunch,
  }) {
    return BackgroundLocationRuntimeStatus(
      activeContexts: activeContexts ?? this.activeContexts,
      isNativePlatformSupported:
          isNativePlatformSupported ?? this.isNativePlatformSupported,
      isNativeServiceRunning:
          isNativeServiceRunning ?? this.isNativeServiceRunning,
      permission: permission ?? this.permission,
      lastAcceptedLocationAt: identical(lastAcceptedLocationAt, _unset)
          ? this.lastAcceptedLocationAt
          : lastAcceptedLocationAt as DateTime?,
      lastErrorCode: identical(lastErrorCode, _unset)
          ? this.lastErrorCode
          : lastErrorCode as String?,
      lastErrorMessage: identical(lastErrorMessage, _unset)
          ? this.lastErrorMessage
          : lastErrorMessage as String?,
      wasRestoredAfterRelaunch:
          wasRestoredAfterRelaunch ?? this.wasRestoredAfterRelaunch,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is BackgroundLocationRuntimeStatus &&
            _setsEqual(activeContexts, other.activeContexts) &&
            isNativePlatformSupported == other.isNativePlatformSupported &&
            isNativeServiceRunning == other.isNativeServiceRunning &&
            permission == other.permission &&
            lastAcceptedLocationAt == other.lastAcceptedLocationAt &&
            lastErrorCode == other.lastErrorCode &&
            lastErrorMessage == other.lastErrorMessage &&
            wasRestoredAfterRelaunch == other.wasRestoredAfterRelaunch;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAllUnordered(activeContexts),
        isNativePlatformSupported,
        isNativeServiceRunning,
        permission,
        lastAcceptedLocationAt,
        lastErrorCode,
        lastErrorMessage,
        wasRestoredAfterRelaunch,
      );

  static bool _setsEqual<T>(Set<T> left, Set<T> right) =>
      left.length == right.length && left.containsAll(right);

  static const Object _unset = Object();
}
