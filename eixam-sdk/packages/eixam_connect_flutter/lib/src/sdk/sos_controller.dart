import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

/// Presentation-oriented controller for the SOS workflow.
///
/// The controller subscribes to the SDK state stream and exposes a simple API
/// that is convenient for Flutter widgets.
class SosController extends ChangeNotifier {
  SosController({required this.sdk});

  final EixamConnectSdk sdk;

  SosState _state = SosState.idle;
  SosIncident? _lastIncident;
  bool _busy = false;
  String? _lastError;
  StreamSubscription<SosState>? _subscription;

  SosState get state => _state;
  SosIncident? get lastIncident => _lastIncident;
  bool get isBusy => _busy;
  String? get lastError => _lastError;

  bool get canTrigger =>
      !_busy &&
      (_state == SosState.idle ||
          _state == SosState.failed ||
          _state == SosState.cancelled ||
          _state == SosState.resolved);

  bool get canCancel => !_busy && !canTrigger;

  /// Loads the current SOS state and subscribes to future updates.
  Future<void> initialize() async {
    _state = await sdk.getSosState();
    _subscription = sdk.watchSosState().listen((state) {
      _state = state;
      notifyListeners();
    });
    notifyListeners();
  }

  /// Triggers a new SOS incident if the current state allows it.
  Future<void> trigger({String? message}) async {
    if (!canTrigger) return;
    _setBusy(true);
    _lastError = null;
    try {
      _lastIncident = await sdk.triggerSos(message: message);
    } on EixamSdkException catch (error) {
      _lastError = error.message;
    } finally {
      _setBusy(false);
    }
  }

  /// Cancels the active SOS incident when cancellation is still allowed.
  Future<void> cancel({String? reason}) async {
    if (!canCancel) return;
    _setBusy(true);
    _lastError = null;
    try {
      _lastIncident = await sdk.cancelSos(reason: reason);
    } on EixamSdkException catch (error) {
      _lastError = error.message;
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
