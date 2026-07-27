import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:geolocator/geolocator.dart';

import '../datasources_local/shared_prefs_sdk_store.dart';
import '../../mappers/local_state_serializers.dart';
import '../../sdk/latest_phone_position_sink.dart';
import '../../sdk/sos_location_trace.dart';

/// Tracking repository backed by `geolocator`.
///
/// The repository exposes live positions and tracking state, and can also cache
/// the most recent values locally so the SDK can restore them on the next app
/// launch.
class GeolocatorTrackingRepository
    implements TrackingRepository, LatestPhonePositionSink {
  GeolocatorTrackingRepository({
    required this.permissionsRepository,
    SharedPrefsSdkStore? localStore,
    this.locationSettings = const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    ),
    this.staleAfter = const Duration(seconds: 30),
  }) : _localStore = localStore {
    _positionsController = StreamController<TrackingPosition>.broadcast(
      onListen: () => _positionObserverCount += 1,
      onCancel: () {
        if (_positionObserverCount > 0) {
          _positionObserverCount -= 1;
        }
      },
    );
  }

  final PermissionsRepository permissionsRepository;
  final SharedPrefsSdkStore? _localStore;
  final LocationSettings locationSettings;
  final Duration staleAfter;

  late final StreamController<TrackingPosition> _positionsController;
  final StreamController<TrackingState> _trackingStateController =
      StreamController.broadcast();

  StreamSubscription<Position>? _subscription;
  Timer? _freshnessTimer;
  TrackingPosition? _lastPosition;
  TrackingState _state = TrackingState.idle;
  int _positionObserverCount = 0;
  bool _disposed = false;

  @override
  TrackingPosition? get latestPhonePosition => _lastPosition;

  /// Restores the cached tracking state and last known position.
  Future<void> restoreState() async {
    if (_disposed) return;
    if (_localStore == null) return;

    final positionJson =
        await _localStore.readJson(SharedPrefsSdkStore.trackingPositionKey);
    final stateRaw =
        await _localStore.readString(SharedPrefsSdkStore.trackingStateKey);

    if (positionJson != null) {
      _lastPosition =
          LocalStateSerializers.trackingPositionFromJson(positionJson);
      if (_disposed || _positionsController.isClosed) return;
      _positionsController.add(_lastPosition!);
    }

    _state = TrackingState.values.firstWhere(
      (value) => value.name == stateRaw,
      orElse: () => _lastPosition?.isStale == true
          ? TrackingState.stale
          : TrackingState.idle,
    );
    if (_disposed || _trackingStateController.isClosed) return;
    _trackingStateController.add(_state);
  }

  @override
  Future<TrackingPosition?> getCurrentPosition() async {
    _throwIfDisposed();
    await _ensureLocationPermission();

    try {
      final position = await Geolocator.getCurrentPosition(
          locationSettings: locationSettings);
      if (_disposed) return _lastPosition;
      await acceptPhonePosition(
        _mapPosition(position),
        source: PhonePositionSource.oneShot,
      );
      _setState(TrackingState.tracking);
      _restartFreshnessTimer();
      await _persistState();
      return _lastPosition;
    } catch (error) {
      _setState(TrackingState.error);
      await _persistState();
      throw TrackingException(
          'E_TRACKING_CURRENT_POSITION_ERROR', error.toString());
    }
  }

  @override
  Future<TrackingState> getTrackingState() async => _state;

  @override
  Future<void> startTracking() async {
    _throwIfDisposed();
    await _ensureLocationPermission();
    _setState(TrackingState.starting);
    await _persistState();

    try {
      final hadPreviousStream = _subscription != null;
      await _subscription?.cancel();
      SosLocationTrace.emit('geolocator_stream', {
        'action': 'previous_cancelled',
        'had_previous_stream': hadPreviousStream,
        'active_streams': 0,
      });
      _subscription =
          Geolocator.getPositionStream(locationSettings: locationSettings)
              .listen(
        (position) async {
          if (_disposed) return;
          await acceptPhonePosition(
            _mapPosition(position),
            source: PhonePositionSource.geolocator,
          );
          _setState(TrackingState.tracking);
          _restartFreshnessTimer();
          await _persistState();
        },
        onError: (Object error, StackTrace stackTrace) async {
          if (_disposed) return;
          _setState(TrackingState.error);
          await _persistState();
          if (!_positionsController.isClosed) {
            _positionsController.addError(
              TrackingException('E_TRACKING_STREAM_ERROR', error.toString()),
              stackTrace,
            );
          }
        },
      );
      SosLocationTrace.emit('geolocator_stream', {
        'action': 'subscribed',
        'active_streams': 1,
      });
    } catch (error) {
      _setState(TrackingState.error);
      await _persistState();
      SosLocationTrace.emit('geolocator_stream', {
        'action': 'subscribe_failed',
        'active_streams': 0,
      });
      throw TrackingException('E_TRACKING_START_ERROR', error.toString());
    }
  }

  @override
  Future<void> stopTracking() async {
    await _subscription?.cancel();
    _subscription = null;
    SosLocationTrace.emit('geolocator_stream', {
      'action': 'cancelled',
      'active_streams': 0,
    });
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    if (_disposed) return;
    _setState(TrackingState.idle);
    await _persistState();
  }

  @override
  Stream<TrackingPosition> watchPositions() async* {
    if (_disposed) return;
    final current = _lastPosition;
    if (current != null) {
      yield current;
    }
    if (_disposed) return;
    yield* _positionsController.stream;
  }

  @override
  Stream<TrackingState> watchTrackingState() async* {
    if (_disposed) return;
    yield _state;
    if (_disposed) return;
    yield* _trackingStateController.stream;
  }

  @override
  Future<bool> acceptPhonePosition(
    TrackingPosition position, {
    required PhonePositionSource source,
  }) async {
    if (_disposed) {
      return false;
    }
    final sourceName = switch (source) {
      PhonePositionSource.nativeContext => 'native_context',
      PhonePositionSource.geolocator => 'geolocator',
      PhonePositionSource.oneShot => 'one_shot',
    };
    if (!_isValidPosition(position)) {
      _tracePositionCache(
        action: 'ignored',
        source: sourceName,
        reason: 'invalid',
      );
      return false;
    }
    final current = _lastPosition;
    if (current != null) {
      if (_isSamePosition(position, current)) {
        _tracePositionCache(
          action: 'ignored',
          source: sourceName,
          reason: 'duplicate',
        );
        return false;
      }
      if (!position.timestamp.isAfter(current.timestamp)) {
        _tracePositionCache(
          action: 'ignored',
          source: sourceName,
          reason: 'older_sample',
        );
        return false;
      }
    }
    _lastPosition = position;
    _addPosition(position);
    await _persistState();
    _tracePositionCache(
      action: 'updated',
      source: sourceName,
      reason: 'newer_sample',
    );
    return true;
  }

  Future<void> _ensureLocationPermission() async {
    final state = await permissionsRepository.getPermissionState();
    if (!state.hasLocationAccess) {
      _setState(TrackingState.error);
      throw const TrackingException(
        'E_LOCATION_PERMISSION_REQUIRED',
        'E_LOCATION_PERMISSION_REQUIRED',
      );
    }
  }

  void _restartFreshnessTimer() {
    if (_disposed) return;
    _freshnessTimer?.cancel();
    _freshnessTimer = Timer(staleAfter, () async {
      if (!_disposed && _state == TrackingState.tracking) {
        _setState(TrackingState.stale);
        await _persistState();
      }
    });
  }

  void _setState(TrackingState newState) {
    if (_state == newState) return;
    _state = newState;
    if (!_disposed && !_trackingStateController.isClosed) {
      _trackingStateController.add(newState);
    }
  }

  void _addPosition(TrackingPosition position) {
    if (!_disposed && !_positionsController.isClosed) {
      _positionsController.add(position);
    }
  }

  TrackingPosition _mapPosition(Position position) {
    return TrackingPosition(
      latitude: position.latitude,
      longitude: position.longitude,
      altitude: position.altitude,
      accuracy: position.accuracy,
      speed: position.speed,
      heading: position.heading,
      source: DeliveryMode.mobile,
      timestamp: position.timestamp,
    );
  }

  bool _isValidPosition(TrackingPosition position) =>
      position.latitude.isFinite &&
      position.longitude.isFinite &&
      position.latitude >= -90 &&
      position.latitude <= 90 &&
      position.longitude >= -180 &&
      position.longitude <= 180 &&
      (position.accuracy == null ||
          (position.accuracy!.isFinite && position.accuracy! >= 0));

  bool _isSamePosition(
    TrackingPosition first,
    TrackingPosition second,
  ) =>
      first.timestamp == second.timestamp &&
      first.latitude == second.latitude &&
      first.longitude == second.longitude;

  void _tracePositionCache({
    required String action,
    required String source,
    required String reason,
  }) {
    SosLocationTrace.emit('ios_position_cache', {
      'action': action,
      'source': source,
      'reason': reason,
      'observer_count': _positionObserverCount,
    });
  }

  Future<void> _persistState() async {
    if (_disposed) return;
    if (_localStore == null) return;

    await _localStore.saveString(
        SharedPrefsSdkStore.trackingStateKey, _state.name);
    if (_lastPosition == null) {
      await _localStore.remove(SharedPrefsSdkStore.trackingPositionKey);
      return;
    }

    await _localStore.saveJson(
      SharedPrefsSdkStore.trackingPositionKey,
      LocalStateSerializers.trackingPositionToJson(_lastPosition!),
    );
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('GeolocatorTrackingRepository has been disposed.');
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    SosLocationTrace.emit('geolocator_stream', {
      'action': 'disposed',
      'active_streams': 0,
    });
    await _positionsController.close();
    await _trackingStateController.close();
  }
}
