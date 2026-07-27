import 'dart:async';
import 'dart:math' as math;

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_debug_registry.dart';
import 'authoritative_sos_cadence.dart';
import 'latest_phone_position_sink.dart';
import 'location_debug_log.dart';
import 'sos_location_trace.dart';

typedef OperationalTelemetrySessionProvider = EixamSession? Function();
typedef OperationalTelemetryPayloadPublisher = Future<void> Function(
  SdkTelemetryPayload payload,
);
typedef OperationalResolvedLocationProvider = Future<SdkResolvedLocation?>
    Function();
typedef OperationalTelemetryClock = DateTime Function();
typedef OperationalTelemetryLogger = void Function(String message);

class OperationalTelemetryCoordinator {
  OperationalTelemetryCoordinator({
    required TrackingRepository trackingRepository,
    required Stream<AuthoritativeSosCadence> authoritativeSosCadenceStream,
    required OperationalTelemetrySessionProvider sessionProvider,
    required OperationalTelemetryPayloadPublisher publishTelemetry,
    required OperationalResolvedLocationProvider resolvedLocationProvider,
    Duration normalInterval = const Duration(seconds: 60),
    Duration sosInterval = const Duration(seconds: 20),
    double sosMovementThresholdMeters = 7,
    OperationalTelemetryClock? clock,
    OperationalTelemetryLogger? logger,
  })  : _trackingRepository = trackingRepository,
        _authoritativeSosCadenceStream = authoritativeSosCadenceStream,
        _sessionProvider = sessionProvider,
        _publishTelemetry = publishTelemetry,
        _resolvedLocationProvider = resolvedLocationProvider,
        _normalInterval = normalInterval,
        _sosInterval = sosInterval,
        _sosMovementThresholdMeters = sosMovementThresholdMeters,
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _logger = logger ??
            ((message) => BleDebugRegistry.instance.recordEvent(message));

  final TrackingRepository _trackingRepository;
  final Stream<AuthoritativeSosCadence> _authoritativeSosCadenceStream;
  final OperationalTelemetrySessionProvider _sessionProvider;
  final OperationalTelemetryPayloadPublisher _publishTelemetry;
  final OperationalResolvedLocationProvider _resolvedLocationProvider;
  final Duration _normalInterval;
  final Duration _sosInterval;
  final double _sosMovementThresholdMeters;
  final OperationalTelemetryClock _clock;
  final OperationalTelemetryLogger _logger;

  StreamSubscription<AuthoritativeSosCadence>? _sosCadenceSub;
  StreamSubscription<TrackingPosition>? _positionSub;
  Timer? _timer;
  bool _started = false;
  bool _sosCadenceActive = false;
  SosLifecycleStage _authoritativeLifecycleStage = SosLifecycleStage.idle;
  bool _intervalPublishingEnabled = true;
  bool _publishInFlight = false;
  SdkResolvedLocation? _lastPublishedSosLocation;

  bool get isRunning => _started;

  void setIntervalPublishingEnabled(bool enabled) {
    if (_intervalPublishingEnabled == enabled) {
      return;
    }
    _intervalPublishingEnabled = enabled;
    if (_started) {
      _startTimerForCurrentMode();
    }
  }

  void start({required AuthoritativeSosCadence initialCadence}) {
    if (_started) {
      return;
    }
    _started = true;
    _sosCadenceActive = initialCadence.desiredLocalSosOwnership;
    _authoritativeLifecycleStage = initialCadence.lifecycleStage;
    _lastPublishedSosLocation = null;
    _sosCadenceSub = _authoritativeSosCadenceStream.listen(
      _handleAuthoritativeSosCadence,
      onError: (Object _) {
        _logger(
          '[SDK_TELEMETRY_LOOP] action=skip '
          'reason=authoritative_sos_cadence_stream_error '
          'error_category=stream',
        );
      },
    );
    _positionSub = _trackingRepository.watchPositions().listen(
      _handlePosition,
      onError: (Object _) {
        _logger(
          '[SDK_TELEMETRY_LOOP] action=skip '
          'reason=position_stream_error error_category=stream',
        );
      },
    );
    if (_sosCadenceActive) {
      unawaited(_primeSosMovementAnchor());
    }
    _startTimerForCurrentMode();
    SosLocationTrace.emit('publication_loop', {
      'action': 'start',
      ..._cadenceTraceFields,
      'loop_count': 1,
    });
  }

  Future<void> stop() async {
    if (!_started &&
        _timer == null &&
        _sosCadenceSub == null &&
        _positionSub == null) {
      return;
    }
    _started = false;
    _timer?.cancel();
    _timer = null;
    await _sosCadenceSub?.cancel();
    await _positionSub?.cancel();
    _sosCadenceSub = null;
    _positionSub = null;
    _lastPublishedSosLocation = null;
    _logger('[SDK_TELEMETRY_LOOP] action=stop');
    SosLocationTrace.emit('publication_loop', {
      'action': 'stop',
      'loop_count': 0,
      'publish_in_flight': _publishInFlight,
      'timer_active': _timer != null,
      'position_subscription_active': _positionSub != null,
      'sos_cadence_subscription_active': _sosCadenceSub != null,
    });
  }

  Future<void> evaluateNow({required String reason}) async {
    if (!_started) {
      return;
    }
    await _publishFromCurrentLocation(reason: reason);
  }

  void _handleAuthoritativeSosCadence(AuthoritativeSosCadence cadence) {
    _authoritativeLifecycleStage = cadence.lifecycleStage;
    final nextActive = cadence.desiredLocalSosOwnership;
    SosLocationTrace.emit('telemetry_cadence_decision', {
      ..._cadenceTraceFieldsFor(nextActive),
      'lifecycle_revision': cadence.lifecycleRevision,
    });
    if (nextActive == _sosCadenceActive) {
      return;
    }
    _sosCadenceActive = nextActive;
    _lastPublishedSosLocation = null;
    if (_sosCadenceActive) {
      unawaited(_primeSosMovementAnchor());
    }
    _startTimerForCurrentMode();
  }

  void _handlePosition(TrackingPosition position) {
    if (!_started || !_sosCadenceActive || !_hasValidLocation(position)) {
      return;
    }
    final anchor = _lastPublishedSosLocation;
    if (anchor == null) {
      _lastPublishedSosLocation = _resolvedLocationFromTracking(position);
      return;
    }
    final distance = distanceMeters(
      anchor,
      _resolvedLocationFromTracking(position),
    );
    if (distance < _sosMovementThresholdMeters) {
      return;
    }
    unawaited(
      _publishFromCurrentLocation(reason: 'sos_moved'),
    );
  }

  Future<void> _primeSosMovementAnchor() async {
    try {
      final cached = _trackingRepository is LatestPhonePositionSink
          ? (_trackingRepository as LatestPhonePositionSink).latestPhonePosition
          : null;
      final position = cached ?? await _trackingRepository.getCurrentPosition();
      if (_sosCadenceActive && _hasValidLocation(position)) {
        _lastPublishedSosLocation = _resolvedLocationFromTracking(position!);
      }
    } catch (_) {
      // The interval publisher will log no_location if location remains absent.
    }
  }

  void _startTimerForCurrentMode() {
    _timer?.cancel();
    _timer = null;
    if (!_intervalPublishingEnabled) {
      _logger(
          '[SDK_TELEMETRY_LOOP] action=pause reason=native_background_owner');
      SosLocationTrace.emit('publication_loop', {
        'action': 'pause',
        'reason': 'native_background_owner',
        ..._cadenceTraceFields,
        'loop_count': 0,
      });
      return;
    }
    if (_sosCadenceActive) {
      _logger(
        '[SDK_TELEMETRY_LOOP] action=start mode=sos '
        'interval=${_sosInterval.inSeconds}s '
        'movementThreshold=${_sosMovementThresholdMeters.toStringAsFixed(0)}m',
      );
      SosLocationTrace.emit('publication_loop', {
        'action': 'configure',
        ..._cadenceTraceFields,
        'publication_reason': 'sos_interval',
        'loop_count': 1,
      });
      _timer = Timer.periodic(
        _sosInterval,
        (_) => unawaited(_publishFromCurrentLocation(reason: 'sos_interval')),
      );
      return;
    }
    _logger(
      '[SDK_TELEMETRY_LOOP] action=start mode=normal '
      'interval=${_normalInterval.inSeconds}s',
    );
    SosLocationTrace.emit('publication_loop', {
      'action': 'configure',
      ..._cadenceTraceFields,
      'publication_reason': 'normal_heartbeat',
      'loop_count': 1,
    });
    _timer = Timer.periodic(
      _normalInterval,
      (_) => unawaited(
        _publishFromCurrentLocation(reason: 'normal_heartbeat'),
      ),
    );
  }

  Future<void> _publishFromCurrentLocation({required String reason}) async {
    SdkResolvedLocation? location;
    try {
      location = await _resolvedLocationProvider();
    } catch (_) {
      _logger(
        '[SDK_TELEMETRY_LOOP] action=skip '
        'reason=no_location error_category=provider',
      );
      SosLocationTrace.emit('telemetry_source', {
        'reason': reason,
        'source': 'none',
        'accepted': false,
        'error_category': 'provider',
      });
      return;
    }
    final validResolved = _hasValidResolvedLocation(location);
    SosLocationTrace.emit('telemetry_source', {
      'reason': reason,
      'source': validResolved ? location?.source.name : 'none',
      'accepted': validResolved,
    });
    LocationDebugLog.resolved(
      flow: 'telemetry_publish_candidate',
      location: location,
      accepted: validResolved,
      rejectionReason: validResolved ? null : 'invalid_resolved_location',
      sentToBackend: false,
    );
    if (!validResolved) {
      _logger('[SDK_TELEMETRY_LOOP] action=skip reason=no_location');
      return;
    }
    await _publishResolvedLocation(location!, reason: reason);
  }

  Future<void> _publishResolvedLocation(
    SdkResolvedLocation location, {
    required String reason,
    double? distanceMeters,
  }) async {
    if (_publishInFlight) {
      _logger('[SDK_TELEMETRY_LOOP] action=skip reason=publish_in_flight');
      SosLocationTrace.emit('publication', {
        'action': 'skip',
        'reason': 'publish_in_flight',
        'source': location.source.name,
      });
      return;
    }
    final session = _sessionProvider();
    if (session == null) {
      _logger('[SDK_TELEMETRY_LOOP] action=skip reason=missing_session');
      SosLocationTrace.emit('publication', {
        'action': 'skip',
        'reason': 'missing_session',
        'source': location.source.name,
      });
      return;
    }
    _publishInFlight = true;
    SosLocationTrace.emit('publication', {
      'action': 'attempt',
      'reason': reason,
      'source': location.source.name,
      ..._cadenceTraceFields,
    });
    try {
      final payload = SdkTelemetryPayload(
        timestamp: _clock().toUtc(),
        latitude: location.latitude,
        longitude: location.longitude,
        altitude: location.altitudeMeters ?? 0,
        deviceId: location.deviceId,
        hardwareId: location.hardwareId,
        nodeId: location.nodeId,
        identitySource: switch (location.source) {
          SdkLocationSource.connectedDevice => 'ble_node',
          SdkLocationSource.phone => 'app',
          SdkLocationSource.remoteRelayDevice => 'remote_relay',
          _ => null,
        },
      );
      LocationDebugLog.telemetryPayload(
        flow: 'telemetry_publish_final',
        payload: payload,
        accepted: true,
        source: location.source.name,
        sentToBackend: true,
      );
      await _publishTelemetry(payload);
      if (_sosCadenceActive) {
        _lastPublishedSosLocation = location;
      }
      final distanceFragment = distanceMeters == null
          ? ''
          : ' distanceMeters=${distanceMeters.toStringAsFixed(2)}';
      _logger(
        '[SDK_TELEMETRY_LOOP] action=publish reason=$reason$distanceFragment',
      );
      SosLocationTrace.emit('publication', {
        'action': 'success',
        'reason': reason,
        'source': location.source.name,
        ..._cadenceTraceFields,
      });
    } catch (_) {
      _logger(
        '[SDK_TELEMETRY_LOOP] action=skip '
        'reason=publish_error error_category=publish',
      );
      SosLocationTrace.emit('publication', {
        'action': 'failure',
        'reason': reason,
        'source': location.source.name,
        'error_category': 'publish',
        ..._cadenceTraceFields,
      });
    } finally {
      _publishInFlight = false;
    }
  }

  Map<String, Object?> get _cadenceTraceFields =>
      _cadenceTraceFieldsFor(_sosCadenceActive);

  Map<String, Object?> _cadenceTraceFieldsFor(bool cadenceActive) =>
      <String, Object?>{
        'sos_cadence_active': cadenceActive,
        'authoritative_stage': _authoritativeLifecycleStage.name,
        'authoritative_desired_ownership': cadenceActive,
        'mode': cadenceActive ? 'sos' : 'normal',
      };

  bool _hasValidLocation(TrackingPosition? position) {
    if (position == null) {
      return false;
    }
    return position.latitude.isFinite &&
        position.latitude >= -90 &&
        position.latitude <= 90 &&
        position.longitude.isFinite &&
        position.longitude >= -180 &&
        position.longitude <= 180;
  }

  bool _hasValidResolvedLocation(SdkResolvedLocation? location) {
    if (location == null || !location.authoritativeForBackend) {
      return false;
    }
    return location.isValid &&
        location.latitude.isFinite &&
        location.latitude >= -90 &&
        location.latitude <= 90 &&
        location.longitude.isFinite &&
        location.longitude >= -180 &&
        location.longitude <= 180;
  }

  SdkResolvedLocation _resolvedLocationFromTracking(TrackingPosition position) {
    return SdkResolvedLocation.fromPhoneTrackingPosition(
      position: position,
      isFresh: !position.isStale,
    );
  }

  static double distanceMeters(SdkResolvedLocation a, SdkResolvedLocation b) {
    const earthRadiusMeters = 6371000.0;
    final lat1 = _degreesToRadians(a.latitude);
    final lat2 = _degreesToRadians(b.latitude);
    final deltaLat = _degreesToRadians(b.latitude - a.latitude);
    final deltaLon = _degreesToRadians(b.longitude - a.longitude);
    final haversine = math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(deltaLon / 2) *
            math.sin(deltaLon / 2);
    final angularDistance =
        2 * math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine));
    return earthRadiusMeters * angularDistance;
  }

  static double _degreesToRadians(double degrees) => degrees * math.pi / 180;
}
