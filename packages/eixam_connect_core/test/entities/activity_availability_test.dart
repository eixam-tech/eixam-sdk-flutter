import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  test('snapshot copies its ordered list and converts SDK metadata to UTC', () {
    const a = SdkAvailableActivity(id: 'a', key: '1ski');
    const b = SdkAvailableActivity(id: 'b', key: '_ski');
    final source = [b, a, b];
    final time = DateTime(2026, 10, 18, 10, 11, 12);
    final snapshot = SdkActivityAvailability(
      activities: source,
      fetchedAt: time,
      fromCache: false,
    );
    source.clear();
    expect(snapshot.activities, [b, a, b]);
    expect(() => snapshot.activities.add(a), throwsUnsupportedError);
    expect(() => snapshot.activities[0] = a, throwsUnsupportedError);
    expect(snapshot.fetchedAt, time.toUtc());
    expect(snapshot.fetchedAt.isUtc, isTrue);
    expect(snapshot.fromCache, isFalse);
  });

  test(
    'capability and error export without expanding the sealed error family',
    () {
      final EixamConnectSdk legacy = _LegacySdk();
      expect(legacy, isNot(isA<ActivityAvailabilityControl>()));
      const error = ActivityAvailabilityException('code', 'message');
      expect(error, isNot(isA<EixamSdkException>()));
      expect(error.toString(), contains('code'));
    },
  );
}

class _LegacySdk implements EixamConnectSdk {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
