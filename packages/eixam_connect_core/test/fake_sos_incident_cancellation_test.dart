import 'dart:async';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';
import 'support/fakes/fake_sos_repository.dart';

void main() {
  test(
    'fake awaits lazy getter and cancels idle without another event',
    () async {
      final repository = _DelayedRepository();
      final stream = repository.watchCurrentIncident();
      expect(repository.reads, 0);
      final values = <SosIncident?>[];
      final subscription = stream.listen(values.add);
      await pumpEventQueue();
      expect(repository.reads, 1);
      expect(values, isEmpty);
      repository.value.complete(null);
      await pumpEventQueue();
      expect(values, [null]);
      await subscription.cancel().timeout(const Duration(seconds: 1));
    },
  );
}

class _DelayedRepository extends FakeSosRepository {
  final value = Completer<SosIncident?>();
  int reads = 0;
  @override
  Future<SosIncident?> getCurrentIncident() {
    reads++;
    return value.future;
  }
}
