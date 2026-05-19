import 'package:eixam_connect_core/eixam_connect_core.dart';

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
      return remote;
    }

    final device = _freshConnectedOwnDeviceLocation();
    if (device != null) {
      return device;
    }

    final phone = await _freshPhoneLocation();
    if (phone != null) {
      return phone;
    }

    if (useCase == SdkResolvedLocationUseCase.uiPreview) {
      final backend = _presentationOnly(backendSnapshot);
      if (backend != null) {
        return backend;
      }
      return _presentationOnly(cachedFallback);
    }

    return null;
  }

  SdkResolvedLocation? _authoritativeRemoteRelay(
    SdkResolvedLocation? location,
  ) {
    if (location == null ||
        location.source != SdkLocationSource.remoteRelayDevice) {
      return null;
    }
    final resolved = _withFreshness(location);
    if (!resolved.isValid) {
      return null;
    }
    return resolved.copyWith(authoritativeForBackend: true);
  }

  SdkResolvedLocation? _freshConnectedOwnDeviceLocation() {
    final candidate = _bridgeDiagnosticsProvider().latestOwnDeviceLocation;
    if (candidate == null ||
        candidate.source != SdkLocationSource.connectedDevice) {
      return null;
    }
    final status = _deviceStatusProvider();
    if (status?.connected != true) {
      return null;
    }
    if (!_belongsToCurrentDevice(candidate, status!)) {
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
      return null;
    }
    return resolved.copyWith(authoritativeForBackend: true);
  }

  Future<SdkResolvedLocation?> _freshPhoneLocation() async {
    try {
      final position = await _trackingRepository.getCurrentPosition();
      if (position == null) {
        return null;
      }
      final freshness = _age(position.timestamp);
      final location = SdkResolvedLocation.fromPhoneTrackingPosition(
        position: position,
        freshness: freshness,
        isFresh: freshness <= _freshnessThreshold,
      );
      if (!location.isValid || !location.isFresh) {
        return null;
      }
      return location;
    } catch (_) {
      return null;
    }
  }

  SdkResolvedLocation? _presentationOnly(SdkResolvedLocation? location) {
    if (location == null) {
      return null;
    }
    final resolved = _withFreshness(location);
    if (!resolved.isValid) {
      return null;
    }
    return resolved.copyWith(authoritativeForBackend: false);
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
