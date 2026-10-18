import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  for (final key in [
    'mountain',
    'ski',
    'hunting',
    'trail_running',
    'via-ferrata',
    'org.example.paddling',
    'unknown_future_activity',
    'a',
    'a' * 64,
  ]) {
    test('accepts arbitrary valid key $key', () {
      expect(
        () => SdkActivitySession.validateActivityKey(key),
        returnsNormally,
      );
    });
  }
  for (final key in [
    '',
    'A',
    'mountain ',
    ' ski',
    'ski\n',
    'ski\r\n',
    'a' * 65,
    'ski..tour',
    'ski__tour',
    'ski-',
    '.ski',
    'ski/tour',
    'esquí',
    '1ski',
  ]) {
    test('rejects invalid key ${key.codeUnits}', () {
      expect(
        () => SdkActivitySession.validateActivityKey(key),
        throwsA(
          isA<ActivitySessionException>().having(
            (e) => e.code,
            'code',
            'E_ACTIVITY_INVALID_KEY',
          ),
        ),
      );
    });
  }
  test(
    'exports the independent capability without changing legacy implementers',
    () {
      final EixamConnectSdk legacy = _LegacySdk();
      expect(legacy, isNot(isA<ActivitySessionControl>()));
      const error = ActivitySessionException('E_ACTIVITY_CONFLICT', 'conflict');
      expect(error, isNot(isA<EixamSdkException>()));
      expect(error.toString(), contains('E_ACTIVITY_CONFLICT'));
      final session = SdkActivitySession(
        sessionId: 'session',
        activityKey: 'org.example.paddling',
        startedAt: DateTime.utc(2026),
      );
      expect(session.startedAt.isUtc, isTrue);
    },
  );
}

// Implements the pre-M2 facade only: no ActivitySessionControl members.
class _LegacySdk implements EixamConnectSdk {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
