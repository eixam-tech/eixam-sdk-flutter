import 'package:eixam_connect_flutter/src/diagnostics/sdk_release_log.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_stop_guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// F17c review r7: the single decision before any TAG stop or any backend /
/// REST terminal of the current SOS.
void main() {
  late List<String> lines;
  final closedAt = DateTime.utc(2026, 11, 17, 9, 0, 0);
  final aPublishedAt = closedAt.subtract(const Duration(minutes: 1));
  final bPublishedAt = closedAt.add(const Duration(seconds: 3));

  setUp(() {
    lines = <String>[];
    sdkReleaseLogSinkForTesting = lines.add;
  });
  tearDown(() => sdkReleaseLogSinkForTesting = null);

  SosStopGuard guardWithA() => SosStopGuard()
    ..recordSuperseded(
      SupersededSosEvidence(
        closedAt: closedAt,
        publishedAt: aPublishedAt,
        incidentIds: const <String>['incident-a'],
      ),
    );

  bool allowed(
    SosStopGuard guard,
    SosStopBasis basis, {
    String? incidentId,
    DateTime? occurredAt,
    DateTime? currentPublishedAt,
  }) => guard
      .authorize(
        SosStopRequest(
          kind: SosStopKind.backendTerminal,
          basis: basis,
          source: 'test',
          incidentId: incidentId,
          occurredAt: occurredAt,
          currentPublishedAt: currentPublishedAt,
        ),
      )
      .allowed;

  test('the user and owed stops are always allowed', () {
    final guard = guardWithA();
    expect(allowed(guard, SosStopBasis.userAction), isTrue);
    expect(allowed(guard, SosStopBasis.owedStop), isTrue);
  });

  test('evidence of the superseded SOS never ends the current one', () {
    final guard = guardWithA();
    for (final basis in <SosStopBasis>[
      SosStopBasis.exactIncident,
      SosStopBasis.authorizedUpstream,
      SosStopBasis.userScoped,
    ]) {
      expect(allowed(guard, basis, incidentId: 'incident-a'), isFalse);
    }
    expect(
      allowed(
        guard,
        SosStopBasis.exactOccurredAt,
        occurredAt: aPublishedAt,
        currentPublishedAt: aPublishedAt,
      ),
      isFalse,
    );
    expect(
      lines.where((l) => l.startsWith('SOS_OUTBOX_STOP_GUARD_REFUSED')),
      isNotEmpty,
    );
    expect(lines.any((l) => l.contains('incident-a')), isFalse);
  });

  test('exact evidence of the current SOS is allowed', () {
    final guard = guardWithA();
    expect(
      allowed(guard, SosStopBasis.exactIncident, incidentId: 'incident-b'),
      isTrue,
    );
    expect(
      allowed(
        guard,
        SosStopBasis.exactOccurredAt,
        occurredAt: bPublishedAt,
        currentPublishedAt: bPublishedAt,
      ),
      isTrue,
    );
    expect(
      allowed(
        guard,
        SosStopBasis.exactOccurredAt,
        occurredAt: bPublishedAt.add(const Duration(milliseconds: 1)),
        currentPublishedAt: bPublishedAt,
      ),
      isFalse,
    );
  });

  test('user-scoped evidence is refused while attribution is open, allowed '
      'after the current SOS was confirmed exactly', () {
    final guard = guardWithA();
    expect(allowed(guard, SosStopBasis.userScoped), isFalse);
    guard.closeAttribution('exact_processed');
    expect(allowed(guard, SosStopBasis.userScoped), isTrue);
    expect(
      allowed(guard, SosStopBasis.userScoped, incidentId: 'incident-a'),
      isFalse,
      reason: 'the superseded SOS stays recognised',
    );
  });

  test('an occurrence at or before the close is the superseded SOS\'s; its '
      'id is learned from it', () {
    final guard = guardWithA();
    expect(guard.isSupersededOccurrence(closedAt), isTrue);
    expect(guard.isSupersededOccurrence(bPublishedAt), isFalse);
    guard.learnSupersededIncidentId('incident-a2', aPublishedAt);
    expect(guard.isSupersededIncident('incident-a2'), isTrue);
  });

  test('the attribution state survives a restart (JSON round trip)', () {
    final guard = guardWithA();
    final restored = SosStopGuard()..restoreFromJson(guard.toJson());
    expect(restored.attributionOpen, isTrue);
    expect(restored.isSupersededIncident('incident-a'), isTrue);
    expect(restored.isSupersededOccurrence(aPublishedAt), isTrue);
    restored.clear();
    expect(restored.attributionOpen, isFalse);
    expect(restored.superseded, isEmpty);
  });
}
