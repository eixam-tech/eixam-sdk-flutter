import 'dart:async';
import 'dart:typed_data';

import '../device/eixam_ble_command.dart';
import 'provisioning_command_result.dart';
import 'softsim_provisioning.dart';

final class SoftSimTransportUncertainException implements Exception {
  const SoftSimTransportUncertainException();
}

/// Streams one secret frame at a time while a single transaction-scoped
/// reject observer remains active from BEGIN through COMMIT acknowledgement.
final class SoftSimProvisioningTransport {
  SoftSimProvisioningTransport({
    required this.write,
    required Stream<List<int>> packets,
    required this.ackCoordinator,
    this.rejectionObservationInterval = const Duration(milliseconds: 250),
    this.isCancelled,
    this.cancelled,
  }) : _packets = packets;

  final Future<void> Function(EixamDeviceCommand command) write;
  final Stream<List<int>> _packets;
  final ProvisioningAckCoordinator ackCoordinator;

  /// Firmware drains its BLE notification queue every 100 ms. 250 ms covers
  /// two complete drain cycles plus scheduling margin before the next frame.
  final Duration rejectionObservationInterval;
  final bool Function()? isCancelled;
  final Future<void>? cancelled;

  Future<void> transfer(SoftSimMaterial material) =>
      _transferOnce(material.bytes);

  Future<void> _transferOnce(List<int> bytes) async {
    final rejection = _SoftSimRejectMonitor(_packets);
    await rejection.start();
    try {
      _checkCancellation();
      await _writeSecretFrame('SOFTSIM BEGIN', encodeSoftSimBegin(bytes));
      await _observe(rejection);

      for (var offset = 0; offset < bytes.length; offset += 12) {
        _checkCancellation();
        await _writeSecretFrame(
          'SOFTSIM CHUNK',
          encodeSoftSimChunk(bytes, offset),
        );
        await _observe(rejection);
      }

      // The reject subscription deliberately remains active while the ACK
      // waiter is armed, leaving no last-CHUNK -> COMMIT subscription gap.
      rejection.throwIfRejected();
      final commitAck = ackCoordinator.run(
        expectedOpcode: 0x24,
        expectedDetail: 0x03,
        isCancelled: isCancelled,
        write: () => _writeSecretFrame('SOFTSIM COMMIT', encodeSoftSimCommit()),
      );
      try {
        await Future.any<void>(<Future<void>>[
          commitAck.then<void>((_) {}),
          rejection.signal.then<void>((_) => rejection.throwIfRejected()),
        ]);
      } on ProvisioningCommandRejectedException {
        ackCoordinator.cancelPending();
        rethrow;
      }
      rejection.throwIfRejected();
    } finally {
      await rejection.dispose();
    }
  }

  Future<void> _observe(_SoftSimRejectMonitor rejection) async {
    final delay = Future<void>.delayed(rejectionObservationInterval);
    final cancellation = cancelled;
    if (cancellation == null) {
      await Future.any<void>(<Future<void>>[delay, rejection.signal]);
    } else {
      await Future.any<void>(
          <Future<void>>[delay, rejection.signal, cancellation]);
    }
    _checkCancellation();
    rejection.throwIfRejected();
  }

  Future<void> _writeSecretFrame(String label, Uint8List frame) async {
    final command = EixamDeviceCommand.provisioningFrame(
      label: label,
      bytes: frame,
      secret: true,
    );
    try {
      await write(command);
    } on ProvisioningOperationCancelledException {
      rethrow;
    } catch (_) {
      throw const SoftSimTransportUncertainException();
    } finally {
      // The write Future has settled, so neither transport nor platform should
      // still need the SDK-owned command/frame copies.
      command.dispose();
      frame.fillRange(0, frame.length, 0);
    }
  }

  void _checkCancellation() {
    if (isCancelled?.call() ?? false) {
      throw const ProvisioningOperationCancelledException();
    }
  }
}

final class _SoftSimRejectMonitor {
  _SoftSimRejectMonitor(this._packets);

  final Stream<List<int>> _packets;
  final Completer<void> _signal = Completer<void>();
  StreamSubscription<List<int>>? _subscription;
  ProvisioningCommandRejectedException? _error;

  Future<void> get signal => _signal.future;

  Future<void> start() async {
    _subscription = _packets.listen((packet) {
      final result = ProvisioningCommandResult.tryParse(packet);
      if (result?.opcode == 0x24 &&
          result?.outcome == ProvisioningCommandOutcome.reject) {
        _error ??= const ProvisioningCommandRejectedException(opcode: 0x24);
        if (!_signal.isCompleted) _signal.complete();
      }
    });
  }

  void throwIfRejected() {
    final error = _error;
    if (error != null) throw error;
  }

  Future<void> dispose() async => _subscription?.cancel();
}
