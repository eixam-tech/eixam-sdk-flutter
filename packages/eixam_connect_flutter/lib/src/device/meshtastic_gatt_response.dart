import 'dart:async';

/// Owns a native GATT response listener explicitly. Future.timeout/Stream.first
/// cannot remove that listener when a disconnect interrupts the request.
final class MeshtasticGattResponse<T> {
  MeshtasticGattResponse(Stream<T> responses, {Duration? timeout}) {
    _subscription = responses.listen(
      (value) {
        if (!_result.isCompleted) _result.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_result.isCompleted) _result.completeError(error, stackTrace);
      },
    );
    if (timeout != null) {
      _timer = Timer(
        timeout,
        () => interrupt(
          TimeoutException('GATT cleanup did not settle.', timeout),
        ),
      );
    }
  }
  final Completer<T?> _result = Completer<T?>();
  late final StreamSubscription<T> _subscription;
  Timer? _timer;
  Future<T?> get response => _result.future;
  void interrupt(Object error) {
    if (!_result.isCompleted) _result.completeError(error);
  }

  void noResponseRequired() {
    if (!_result.isCompleted) _result.complete(null);
  }

  Future<void> close() async {
    _timer?.cancel();
    await _subscription.cancel();
  }
}
