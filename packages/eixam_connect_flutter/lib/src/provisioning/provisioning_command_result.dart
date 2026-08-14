import 'dart:async';

enum ProvisioningCommandOutcome { ok, okNoChange, reject }

final class ProvisioningCommandResult {
  const ProvisioningCommandResult(
      {required this.opcode, required this.outcome, required this.detail});
  final int opcode;
  final ProvisioningCommandOutcome outcome;
  final int detail;

  static ProvisioningCommandResult? tryParse(List<int> bytes) {
    if (bytes.length != 6 ||
        bytes[0] != 0xe9 ||
        bytes[1] != 0x7a ||
        bytes[2] != 1) {
      return null;
    }
    final outcome = switch (bytes[4]) {
      0 => ProvisioningCommandOutcome.ok,
      1 => ProvisioningCommandOutcome.okNoChange,
      2 => ProvisioningCommandOutcome.reject,
      _ => null,
    };
    return outcome == null
        ? null
        : ProvisioningCommandResult(
            opcode: bytes[3], outcome: outcome, detail: bytes[5]);
  }
}

final class ProvisioningCommandRejectedException implements Exception {
  const ProvisioningCommandRejectedException({required this.opcode});
  final int opcode;
}

final class ProvisioningCommandTimeoutException implements Exception {
  const ProvisioningCommandTimeoutException({required this.opcode});
  final int opcode;
}

final class ProvisioningCommunicationInterruptedException implements Exception {
  const ProvisioningCommunicationInterruptedException();
}

final class ProvisioningConnectionEpochInvalidException implements Exception {
  const ProvisioningConnectionEpochInvalidException();
}

final class ProvisioningOperationCancelledException implements Exception {
  const ProvisioningOperationCancelledException();
}

/// Serializes ACK-bearing commands and invalidates the BLE connection epoch
/// whenever a command outcome becomes uncertain. E9 7A has no transaction ID,
/// so only a disconnect/reconnect can safely admit another command afterward.
final class ProvisioningAckCoordinator {
  ProvisioningAckCoordinator(
      {required Stream<List<int>> packets,
      this.timeout = const Duration(seconds: 5)}) {
    _subscription = packets.listen(_acceptPacket);
  }

  final Duration timeout;
  late final StreamSubscription<List<int>> _subscription;
  _PendingAck? _pending;
  Future<void> _barrier = Future<void>.value();
  bool _epochValid = true;
  bool _sawDisconnect = false;
  bool _disposed = false;

  bool get connectionEpochValid => _epochValid && !_disposed;

  Future<ProvisioningCommandResult> run({
    required int expectedOpcode,
    required Future<void> Function() write,
    bool allowNoChange = false,
    int? expectedDetail,
    bool Function()? isCancelled,
  }) {
    final result = Completer<ProvisioningCommandResult>();
    final operation = _barrier.then((_) async {
      _throwIfUnavailable(isCancelled);
      final ack = Completer<ProvisioningCommandResult>();
      final pending = _PendingAck(
          opcode: expectedOpcode,
          expectedDetail: expectedDetail,
          completer: ack);
      _pending = pending;
      Timer? timer;
      try {
        timer = Timer(timeout, () {
          if (!ack.isCompleted) {
            _epochValid = false;
            ack.completeError(
                ProvisioningCommandTimeoutException(opcode: expectedOpcode));
          }
        });
        try {
          await write();
        } catch (_) {
          _epochValid = false;
          rethrow;
        }
        final commandResult = await ack.future;
        if (commandResult.outcome == ProvisioningCommandOutcome.reject ||
            (commandResult.outcome == ProvisioningCommandOutcome.okNoChange &&
                !allowNoChange)) {
          throw ProvisioningCommandRejectedException(opcode: expectedOpcode);
        }
        return commandResult;
      } finally {
        timer?.cancel();
        if (identical(_pending, pending)) {
          _pending = null;
        }
      }
    });
    operation.then(result.complete, onError: result.completeError);
    _barrier = operation.then<void>((_) {}, onError: (_) {});
    return result.future;
  }

  void markDisconnected() {
    _epochValid = false;
    _sawDisconnect = true;
    _completePending(const ProvisioningCommunicationInterruptedException());
  }

  void markConnected() {
    if (_sawDisconnect && !_disposed) {
      _sawDisconnect = false;
      _epochValid = true;
    }
  }

  void cancelPending() =>
      _completePending(const ProvisioningOperationCancelledException());

  void _throwIfUnavailable(bool Function()? isCancelled) {
    if (_disposed || (isCancelled?.call() ?? false)) {
      throw const ProvisioningOperationCancelledException();
    }
    if (!_epochValid) {
      throw const ProvisioningConnectionEpochInvalidException();
    }
  }

  void _completePending(Object error) {
    final pending = _pending;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(error);
    }
    _pending = null;
  }

  void _acceptPacket(List<int> bytes) {
    final result = ProvisioningCommandResult.tryParse(bytes);
    final pending = _pending;
    if (!_epochValid ||
        result == null ||
        pending == null ||
        result.opcode != pending.opcode) {
      return;
    }
    if (pending.expectedDetail != null &&
        result.detail != pending.expectedDetail) {
      return;
    }
    if (!pending.completer.isCompleted) {
      pending.completer.complete(result);
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _epochValid = false;
    _completePending(const ProvisioningOperationCancelledException());
    await _subscription.cancel();
  }
}

final class _PendingAck {
  const _PendingAck(
      {required this.opcode,
      required this.expectedDetail,
      required this.completer});
  final int opcode;
  final int? expectedDetail;
  final Completer<ProvisioningCommandResult> completer;
}
