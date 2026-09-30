import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_incoming_event.dart';
import '../provisioning/provisioning_command_result.dart';

/// Serializes the ACK-bearing `SOS_SILENCE` command.
///
/// Firmware CMD results do not carry a transaction id, so only one `0x09`
/// transaction may be in flight. Results for every other opcode are ignored.
final class SosSilenceCommandCoordinator {
  SosSilenceCommandCoordinator({
    required Stream<BleIncomingEvent> incomingEvents,
    this.timeout = const Duration(seconds: 5),
  }) {
    _subscription = incomingEvents.listen(_acceptEvent);
  }

  static const int opcode = 0x09;

  final Duration timeout;
  late final StreamSubscription<BleIncomingEvent> _subscription;
  Completer<SosSilenceOutcome>? _pending;
  bool _disposed = false;

  Future<SosSilenceOutcome> run({required Future<void> Function() write}) {
    final pending = _pending;
    if (pending != null) {
      return pending.future;
    }
    if (_disposed) {
      throw const DeviceException(
        'E_DEVICE_SOS_SILENCE_UNAVAILABLE',
        'E_DEVICE_SOS_SILENCE_UNAVAILABLE',
      );
    }

    final completer = Completer<SosSilenceOutcome>();
    _pending = completer;
    unawaited(_dispatch(completer: completer, write: write));
    return completer.future;
  }

  Future<void> _dispatch({
    required Completer<SosSilenceOutcome> completer,
    required Future<void> Function() write,
  }) async {
    try {
      await write();
      await completer.future.timeout(
        timeout,
        onTimeout: () => throw const DeviceException(
          'E_DEVICE_SOS_SILENCE_TIMEOUT',
          'E_DEVICE_SOS_SILENCE_TIMEOUT',
        ),
      );
    } catch (error, stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    } finally {
      if (identical(_pending, completer)) {
        _pending = null;
      }
    }
  }

  void _acceptEvent(BleIncomingEvent event) {
    final result = event.provisioningCommandResult;
    if (result != null) {
      acceptResult(result);
    }
  }

  /// Accepts a raw result delivered by the native Protection BLE owner.
  void acceptPayload(List<int> payload) {
    final result = ProvisioningCommandResult.tryParse(payload);
    if (result != null) {
      acceptResult(result);
    }
  }

  void acceptResult(ProvisioningCommandResult result) {
    final pending = _pending;
    if (pending == null || pending.isCompleted || result.opcode != opcode) {
      return;
    }
    switch (result.outcome) {
      case ProvisioningCommandOutcome.ok:
        pending.complete(SosSilenceOutcome.silenceApplied);
      case ProvisioningCommandOutcome.okNoChange:
        pending.complete(SosSilenceOutcome.alreadySilent);
      case ProvisioningCommandOutcome.reject:
        pending.completeError(
          const DeviceException(
            'E_DEVICE_SOS_SILENCE_REJECTED',
            'E_DEVICE_SOS_SILENCE_REJECTED',
          ),
        );
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        const DeviceException(
          'E_DEVICE_SOS_SILENCE_UNAVAILABLE',
          'E_DEVICE_SOS_SILENCE_UNAVAILABLE',
        ),
      );
    }
    _pending = null;
    await _subscription.cancel();
  }
}
