import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

/// Controller that adapts SDK tracking streams to Flutter widgets.
class TrackingController extends ChangeNotifier {
  TrackingController({
    required this.sdk,
    this.staleAfter = const Duration(seconds: 30),
  });

  final EixamConnectSdk sdk;
  final Duration staleAfter;

  TrackingPosition? lastPosition;
  String? lastError;
  TrackingState state = TrackingState.idle;
  DateTime? lastPositionAt;

  StreamSubscription<TrackingPosition>? _positionSubscription;
  StreamSubscription<TrackingState>? _stateSubscription;

  bool get started =>
      state == TrackingState.starting ||
      state == TrackingState.tracking ||
      state == TrackingState.stale;

  bool get isStale {
    if (state == TrackingState.stale) return true;
    if (lastPositionAt == null) return false;
    return DateTime.now().difference(lastPositionAt!) > staleAfter;
  }

  /// Loads current tracking state and subscribes to position and status updates.
  Future<void> initialize() async {
    state = await sdk.getTrackingState();
    lastPosition = await sdk.getCurrentPosition();
    lastPositionAt = lastPosition?.timestamp;

    _positionSubscription ??= sdk.watchPositions().listen((position) {
      lastPosition = position;
      lastPositionAt = position.timestamp;
      lastError = null;
      notifyListeners();
    }, onError: (Object error) {
      lastError = error.toString();
      state = TrackingState.error;
      notifyListeners();
    });

    _stateSubscription ??= sdk.watchTrackingState().listen((newState) {
      state = newState;
      notifyListeners();
    }, onError: (Object error) {
      lastError = error.toString();
      state = TrackingState.error;
      notifyListeners();
    });

    notifyListeners();
  }

  /// Starts location tracking through the SDK.
  Future<void> start() async {
    try {
      state = TrackingState.starting;
      notifyListeners();
      await sdk.startTracking();
      lastError = null;
    } catch (error) {
      lastError = error.toString();
      state = TrackingState.error;
      notifyListeners();
      rethrow;
    }
  }

  /// Stops location tracking through the SDK.
  Future<void> stop() async {
    await sdk.stopTracking();
    state = TrackingState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _stateSubscription?.cancel();
    super.dispose();
  }
}
