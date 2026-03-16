import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:geolocator/geolocator.dart';

import '../datasources_local/shared_prefs_sdk_store.dart';
import '../../mappers/local_state_serializers.dart';

/// Tracking repository backed by `geolocator`.
///
/// The repository exposes live positions and tracking state, and can also cache
/// the most recent values locally so the SDK can restore them on the next app
/// launch.
class GeolocatorTrackingRepository implements TrackingRepository {
  GeolocatorTrackingRepository({
    required this.permissionsRepository,
    SharedPrefsSdkStore? localStore,
    this.locationSettings = const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    ),
    this.staleAfter = const Duration(seconds: 30),
  }) : _localStore = localStore;

  final PermissionsRepository permissionsRepository;
  final SharedPrefsSdkStore? _localStore;
  final LocationSettings locationSettings;
  final Duration staleAfter;

  final StreamController<TrackingPosition> _positionsController = StreamController.broadcast();
  final StreamController<TrackingState> _trackingStateController = StreamController.broadcast();

  StreamSubscription<Position>? _subscription;
  Timer? _freshnessTimer;
  TrackingPosition? _lastPosition;
  TrackingState _state = TrackingState.idle;

  /// Restores the cached tracking state and last known position.
  Future<void> restoreState() async {
    if (_localStore == null) return;

    final positionJson = await _localStore.readJson(SharedPrefsSdkStore.trackingPositionKey);
    final stateRaw = await _localStore.readString(SharedPrefsSdkStore.trackingStateKey);

    if (positionJson != null) {
      _lastPosition = LocalStateSerializers.trackingPositionFromJson(positionJson);
      _positionsController.add(_lastPosition!);
    }

    _state = TrackingState.values.firstWhere(
      (value) => value.name == stateRaw,
      orElse: () => _lastPosition?.isStale == true ? TrackingState.stale : TrackingState.idle,
    );
    _trackingStateController.add(_state);
  }

  @override
  Future<TrackingPosition?> getCurrentPosition() async {
    await _ensureLocationPermission();

    try {
      final position = await Geolocator.getCurrentPosition(locationSettings: locationSettings);
      _lastPosition = _mapPosition(position);
      _positionsController.add(_lastPosition!);
      _setState(TrackingState.tracking);
      _restartFreshnessTimer();
      await _persistState();
      return _lastPosition;
    } catch (error) {
      _setState(TrackingState.error);
      await _persistState();
      throw TrackingException('E_TRACKING_CURRENT_POSITION_ERROR', error.toString());
    }
  }

  @override
  Future<TrackingState> getTrackingState() async => _state;

  @override
  Future<void> startTracking() async {
    await _ensureLocationPermission();
    _setState(TrackingState.starting);
    await _persistState();

    try {
      await _subscription?.cancel();
      _subscription = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
        (position) async {
          _lastPosition = _mapPosition(position);
          _positionsController.add(_lastPosition!);
          _setState(TrackingState.tracking);
          _restartFreshnessTimer();
          await _persistState();
        },
        onError: (Object error, StackTrace stackTrace) async {
          _setState(TrackingState.error);
          await _persistState();
          _positionsController.addError(
            TrackingException('E_TRACKING_STREAM_ERROR', error.toString()),
            stackTrace,
          );
        },
      );
    } catch (error) {
      _setState(TrackingState.error);
      await _persistState();
      throw TrackingException('E_TRACKING_START_ERROR', error.toString());
    }
  }

  @override
  Future<void> stopTracking() async {
    await _subscription?.cancel();
    _subscription = null;
    _freshnessTimer?.cancel();
    _setState(TrackingState.idle);
    await _persistState();
  }

  @override
  Stream<TrackingPosition> watchPositions() => _positionsController.stream;

  @override
  Stream<TrackingState> watchTrackingState() async* {
    yield _state;
    yield* _trackingStateController.stream;
  }

  Future<void> _ensureLocationPermission() async {
    final state = await permissionsRepository.getPermissionState();
    if (!state.hasLocationAccess) {
      _setState(TrackingState.error);
      throw const TrackingException('E_LOCATION_PERMISSION_REQUIRED', 'Location permission is required');
    }
  }

  void _restartFreshnessTimer() {
    _freshnessTimer?.cancel();
    _freshnessTimer = Timer(staleAfter, () async {
      if (_state == TrackingState.tracking) {
        _setState(TrackingState.stale);
        await _persistState();
      }
    });
  }

  void _setState(TrackingState newState) {
    if (_state == newState) return;
    _state = newState;
    _trackingStateController.add(newState);
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
      timestamp: position.timestamp ?? DateTime.now(),
    );
  }

  Future<void> _persistState() async {
    if (_localStore == null) return;

    await _localStore.saveString(SharedPrefsSdkStore.trackingStateKey, _state.name);
    if (_lastPosition == null) {
      await _localStore.remove(SharedPrefsSdkStore.trackingPositionKey);
      return;
    }

    await _localStore.saveJson(
      SharedPrefsSdkStore.trackingPositionKey,
      LocalStateSerializers.trackingPositionToJson(_lastPosition!),
    );
  }
}
