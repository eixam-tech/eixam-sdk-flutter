import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

/// Flutter-friendly controller that exposes pairing, activation and device
/// health actions as observable UI state.
class DeviceController extends ChangeNotifier {
  DeviceController({required this.sdk});

  final EixamConnectSdk sdk;

  DeviceStatus? status;
  bool isBusy = false;
  String? lastError;

  StreamSubscription<DeviceStatus>? _subscription;

  bool get isPaired => status?.paired ?? false;
  bool get isActivated => status?.activated ?? false;
  bool get isReadyForSafety => status?.isReadyForSafety ?? false;
  bool get canPair => !isBusy && !(status?.paired ?? false);
  bool get canActivate =>
      !isBusy && (status?.paired ?? false) && !(status?.activated ?? false);
  DeviceLifecycleState get lifecycleState =>
      status?.lifecycleState ?? DeviceLifecycleState.unpaired;

  /// Loads the latest status and subscribes to runtime updates.
  Future<void> initialize() async {
    status = await sdk.getDeviceStatus();
    notifyListeners();
    _subscription ??= sdk.watchDeviceStatus().listen((next) {
      status = next;
      notifyListeners();
    }, onError: (Object error) {
      lastError = error.toString();
      notifyListeners();
    });
  }

  Future<void> pair(String pairingCode) => _run(() async {
        status = await sdk.pairDevice(pairingCode: pairingCode);
      });

  Future<void> activate(String activationCode) => _run(() async {
        status = await sdk.activateDevice(activationCode: activationCode);
      });

  Future<void> refresh() => _run(() async {
        status = await sdk.refreshDeviceStatus();
      }, clearError: false);

  Future<void> unpair() => _run(() async {
        await sdk.unpairDevice();
        status = await sdk.getDeviceStatus();
      });

  Future<void> _run(Future<void> Function() action,
      {bool clearError = true}) async {
    isBusy = true;
    if (clearError) lastError = null;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      lastError = error.toString();
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
