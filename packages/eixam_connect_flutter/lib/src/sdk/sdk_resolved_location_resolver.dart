import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'location_debug_log.dart';

enum SdkResolvedLocationUseCase {
  emergencyBackend,
  telemetryBackend,
  uiPreview,
}

typedef DeviceStatusSnapshotProvider = DeviceStatus? Function();
typedef BridgeDiagnosticsSnapshotProvider = SdkBridgeDiagnostics Function();

class SdkResolvedLocationResolver {
  const SdkResolvedLocationResolver({
    required TrackingRepository trackingRepository,
    required DeviceStatusSnapshotProvider deviceStatusProvider,
    required BridgeDiagnosticsSnapshotProvider bridgeDiagnosticsProvider,
    DateTime Function()? clock,
    Duration freshnessThreshold = const Duration(minutes: 2),
  })  : _trackingRepository = trackingRepository,
        _deviceStatusProvider = deviceStatusProvider,
        _bridgeDiagnosticsProvider = bridgeDiagnosticsProvider,
        _clock = clock ?? DateTime.now,
        _freshnessThreshold = freshnessThreshold;

  final TrackingRepository _trackingRepository;
  final DeviceStatusSnapshotProvider _deviceStatusProvider;
  final BridgeDiagnosticsSnapshotProvider _bridgeDiagnosticsProvider;
  final DateTime Function() _clock;
  final Duration _freshnessThreshold;

  Future<SdkResolvedLocation?> resolve({
    required SdkResolvedLocationUseCase useCase,
    SdkResolvedLocation? remoteRelayLocation,
    SdkResolvedLocation? backendSnapshot,
    SdkResolvedLocation? cachedFallback,
  }) async {
    final remote = _authoritativeRemoteRelay(remoteRelayLocation);
    if (remote != null) {
      LocationDebugLog.resolved(
        flow: 'resolver_selected',
        location: remote,
        accepted: true,
      );
      return remote;
    }

    final device = _freshConnectedOwnDeviceLocation();
    if (device != null) {
      LocationDebugLog.resolved(
        flow: 'resolver_selected',
        location: device,
        accepted: true,
      );
      return device;
    }

    final phone = await _freshPhoneLocation();
    if (phone != null) {
      LocationDebugLog.resolved(
        flow: 'resolver_selected',
        location: phone,
        accepted: true,
      );
      return phone;
    }

    if (useCase == SdkResolvedLocationUseCase.uiPreview) {
      final backend = _presentationOnly(backendSnapshot);
      if (backend != null) {
        LocationDebugLog.resolved(
          flow: 'resolver_selected',
          location: backend,
          accepted: true,
          note: 'uiPreview',
        );
        return backend;
      }
      final cached = _presentationOnly(cachedFallback);
      if (cached != null) {
        LocationDebugLog.resolved(
          flow: 'resolver_selected',
          location: cached,
          accepted: true,
          note: 'uiPreview',
        );
      }
      return cached;
    }

    LocationDebugLog.resolved(
      flow: 'resolver_selected',
      location: null,
      accepted: false,
      rejectionReason: 'no_authoritative_location',
      note: useCase.name,
    );
    return null;
  }

  SdkResolvedLocation? _authoritativeRemoteRelay(
    SdkResolvedLocation? location,
  ) {
    if (location == null ||
        location.source != SdkLocationSource.remoteRelayDevice) {
      if (location != null) {
        LocationDebugLog.resolved(
          flow: 'resolver_candidate',
          location: location,
          accepted: false,
          rejectionReason: 'not_remote_relay_device',
        );
      }
      return null;
    }
    final resolved = _withFreshness(location);
    if (!resolved.isValid) {
      LocationDebugLog.resolved(
        flow: 'resolver_candidate',
        location: resolved,
        accepted: false,
        rejectionReason: 'invalid_remote_relay_coordinate',
      );
      return null;
    }
    LocationDebugLog.resolved(
      flow: 'resolver_candidate',
      location: resolved,
      accepted: true,
    );
    return resolved.copyWith(authoritativeForBackend: true);
  }

  SdkResolvedLocation? _freshConnectedOwnDeviceLocation() {
    final diagnostics = _bridgeDiagnosticsProvider();
    final candidate = diagnostics.latestOwnDeviceLocation;
    final status = _deviceStatusProvider();
    if (candidate == null) {
      LocationDebugLog.availability(
        flow: 'resolver_candidate',
        source: 'connectedDevice',
        accepted: false,
        rejectionReason: 'no_latest_own_device_location',
        authoritativeForBackend: true,
        candidateExists: false,
        connected: status?.connected ?? false,
        runtimeReady: status?.isReadyForSafety,
        deviceId: status?.deviceId,
        hardwareId: status?.canonicalHardwareId,
        nodeId: status?.nodeId,
        note: 'bridgeActive=${diagnostics.isActive}',
      );
      return null;
    }
    if (candidate.source != SdkLocationSource.connectedDevice) {
      LocationDebugLog.resolved(
        flow: 'resolver_candidate',
        location: candidate,
        accepted: false,
        rejectionReason: 'not_connected_device_candidate',
        note: _candidateNote(candidate, status),
      );
      return null;
    }
    if (status?.connected != true) {
      LocationDebugLog.resolved(
        flow: 'resolver_candidate',
        location: candidate,
        accepted: false,
        rejectionReason: 'device_not_connected',
        note: _candidateNote(candidate, status),
      );
      return null;
    }
    if (!_belongsToCurrentDevice(candidate, status!)) {
      LocationDebugLog.resolved(
        flow: 'resolver_candidate',
        location: candidate,
        accepted: false,
        rejectionReason: 'identity_mismatch',
        note: _candidateNote(candidate, status),
      );
      return null;
    }
    final resolved = _withFreshness(
      candidate.copyWith(
        deviceId: candidate.deviceId ?? status.nodeId?.toString(),
        hardwareId: candidate.hardwareId ?? status.canonicalHardwareId,
        nodeId: candidate.nodeId ?? status.nodeId,
      ),
    );
    if (!resolved.isValid || !resolved.isFresh) {
      LocationDebugLog.resolved(
        flow: 'resolver_candidate',
        location: resolved,
        accepted: false,
        rejectionReason: !resolved.isValid
            ? 'invalid_device_location'
            : 'stale_device_location',
        note: _candidateNote(resolved, status),
      );
      return null;
    }
    LocationDebugLog.resolved(
      flow: 'resolver_candidate',
      location: resolved,
      accepted: true,
      note: _candidateNote(resolved, status),
    );
    return resolved.copyWith(authoritativeForBackend: true);
  }

  Future<SdkResolvedLocation?> _freshPhoneLocation() async {
    try {
      final position = await _trackingRepository.getCurrentPosition();
      if (position == null) {
        LocationDebugLog.resolved(
          flow: 'resolver_candidate',
          location: null,
          accepted: false,
          rejectionReason: 'phone_position_null',
        );
        return null;
      }
      final freshness = _age(position.timestamp);
      final location = SdkResolvedLocation.fromPhoneTrackingPosition(
        position: position,
        freshness: freshness,
        isFresh: freshness <= _freshnessThreshold,
      );
      if (!location.isValid || !location.isFresh) {
        LocationDebugLog.resolved(
          flow: 'resolver_candidate',
          location: location,
          accepted: false,
          rejectionReason: !location.isValid
              ? 'invalid_phone_coordinate'
              : 'stale_phone_coordinate',
        );
        return null;
      }
      LocationDebugLog.resolved(
        flow: 'resolver_candidate',
        location: location,
        accepted: true,
      );
      return location;
    } catch (_) {
      LocationDebugLog.resolved(
        flow: 'resolver_candidate',
        location: null,
        accepted: false,
        rejectionReason: 'phone_position_error',
      );
      return null;
    }
  }

  SdkResolvedLocation? _presentationOnly(SdkResolvedLocation? location) {
    if (location == null) {
      return null;
    }
    final resolved = _withFreshness(location);
    if (!resolved.isValid) {
      LocationDebugLog.resolved(
        flow: 'resolver_candidate',
        location: resolved,
        accepted: false,
        rejectionReason: 'invalid_presentation_coordinate',
      );
      return null;
    }
    final presentation = resolved.copyWith(authoritativeForBackend: false);
    LocationDebugLog.resolved(
      flow: 'resolver_candidate',
      location: presentation,
      accepted: true,
      note: 'presentation_only',
    );
    return presentation;
  }

  SdkResolvedLocation _withFreshness(SdkResolvedLocation location) {
    final freshness = _age(location.timestamp);
    return location.copyWith(
      freshness: freshness,
      isFresh: freshness <= _freshnessThreshold,
      isValid: _isValidCoordinate(location.latitude, location.longitude),
    );
  }

  bool _belongsToCurrentDevice(
    SdkResolvedLocation location,
    DeviceStatus status,
  ) {
    final locationNodeId = location.nodeId;
    final statusNodeId = status.nodeId;
    if (locationNodeId != null &&
        statusNodeId != null &&
        locationNodeId != statusNodeId) {
      return false;
    }
    final locationHardwareId = location.hardwareId?.trim().toLowerCase();
    final statusHardwareId = status.canonicalHardwareId?.trim().toLowerCase();
    if (locationHardwareId != null &&
        locationHardwareId.isNotEmpty &&
        statusHardwareId != null &&
        statusHardwareId.isNotEmpty &&
        locationHardwareId != statusHardwareId) {
      return false;
    }
    return true;
  }

  String _candidateNote(SdkResolvedLocation location, DeviceStatus? status) {
    final freshness = _age(location.timestamp);
    return 'candidateExists=true '
        'connected=${status?.connected ?? false} '
        'runtimeReady=${status?.isReadyForSafety.toString() ?? 'unknown'} '
        'latestTelAgeMs=${freshness.inMilliseconds} '
        'latestTelTimestamp=${location.timestamp.toUtc().toIso8601String()} '
        'candidateNodeId=${location.nodeId?.toString() ?? 'none'} '
        'statusNodeId=${status?.nodeId?.toString() ?? 'none'} '
        'candidateHardwareId=${location.hardwareId ?? 'none'} '
        'statusHardwareId=${status?.canonicalHardwareId ?? 'none'} '
        'statusDeviceId=${status?.deviceId ?? 'none'}';
  }

  bool _isValidCoordinate(double latitude, double longitude) {
    return latitude.isFinite &&
        latitude >= -90 &&
        latitude <= 90 &&
        longitude.isFinite &&
        longitude >= -180 &&
        longitude <= 180 &&
        !(latitude == 0 && longitude == 0);
  }

  Duration _age(DateTime timestamp) {
    final now = _clock().toUtc();
    final normalized = timestamp.toUtc();
    if (normalized.isAfter(now)) {
      return Duration.zero;
    }
    return now.difference(normalized);
  }
}
