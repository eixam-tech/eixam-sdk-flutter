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

  // F17c item 1 (Roger 17/11/2026): an automated native cycle close must name
  // the exact native cycle; only the user's own action targets the current
  // cycle without one.
  group('nativeCycleClose', () {
    SosStopDecision close(
      SosStopGuard guard,
      SosStopBasis basis, {
      String? nativeCycleId,
      String? incidentId,
    }) => guard.authorize(
      SosStopRequest(
        kind: SosStopKind.nativeCycleClose,
        basis: basis,
        source: 'test',
        nativeCycleId: nativeCycleId,
        incidentId: incidentId,
      ),
    );

    test('an automated close without the native cycle id is refused, '
        'logged, never sent', () {
      for (final basis in <SosStopBasis>[
        SosStopBasis.authorizedUpstream,
        SosStopBasis.exactIncident,
        SosStopBasis.exactOccurredAt,
        SosStopBasis.userScoped,
        SosStopBasis.owedStop,
      ]) {
        for (final id in <String?>[null, '', '  ']) {
          final decision = close(SosStopGuard(), basis, nativeCycleId: id);
          expect(decision.allowed, isFalse, reason: '${basis.name} "$id"');
          expect(decision.reason, 'unknown_native_cycle');
        }
      }
      expect(
        lines.where(
          (line) =>
              line.contains('SOS_OUTBOX_STOP_GUARD_REFUSED') &&
              line.contains('kind=nativeCycleClose') &&
              line.contains('reason=unknown_native_cycle') &&
              line.contains('action=keep_sos_active'),
        ),
        hasLength(15),
      );
      // The id itself is never logged.
      close(SosStopGuard(), SosStopBasis.userScoped, nativeCycleId: null);
      expect(lines.join('\n'), isNot(contains('cycle-')));
    });

    test('an automated close with the native cycle id follows the usual '
        'rules', () {
      expect(
        close(
          SosStopGuard(),
          SosStopBasis.authorizedUpstream,
          nativeCycleId: 'cycle-a',
        ).allowed,
        isTrue,
      );
      // A superseded SOS's identity is still refused, id or not.
      expect(
        close(
          guardWithA(),
          SosStopBasis.authorizedUpstream,
          nativeCycleId: 'cycle-a',
          incidentId: 'incident-a',
        ).allowed,
        isFalse,
      );
    });

    test('the user\'s own action targets the current cycle without an id', () {
      final decision = close(guardWithA(), SosStopBasis.userAction);
      expect(decision.allowed, isTrue);
      expect(decision.reason, 'user_action_current_cycle');
      expect(
        close(
          SosStopGuard(),
          SosStopBasis.userAction,
          nativeCycleId: 'cycle-b',
        ).allowed,
        isTrue,
      );
    });
  });

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

  test('the superseded SOS\'s own publish timestamp is its occurrence; its '
      'id is learned from it', () {
    final guard = guardWithA();
    expect(guard.isSupersededOccurrence(aPublishedAt), isTrue);
    expect(guard.isSupersededOccurrence(bPublishedAt), isFalse);
    guard.learnSupersededIncidentId('incident-a2', aPublishedAt);
    expect(guard.isSupersededIncident('incident-a2'), isTrue);
  });

  // r7 LOW-4: only timestamps this phone published belong to a superseded
  // SOS: another source's SOS (LoRa gateway, a second phone of the account,
  // another clock) at or before the close is never taken as the closed one.
  test('an occurrence at or before the close that this phone never published '
      'is not the superseded SOS\'s', () {
    final guard = guardWithA();
    expect(guard.isSupersededOccurrence(closedAt), isFalse);
    expect(
      guard.isSupersededOccurrence(
        closedAt.subtract(const Duration(seconds: 2)),
      ),
      isFalse,
    );
    guard.learnSupersededIncidentId(
      'incident-x',
      closedAt.subtract(const Duration(seconds: 2)),
    );
    expect(guard.isSupersededIncident('incident-x'), isFalse);
  });

  test('an older own publish timestamp at or before the close (restored '
      'after a restart) is a superseded SOS\'s', () {
    final earlier = aPublishedAt.subtract(const Duration(seconds: 30));
    final guard = SosStopGuard()
      ..recordOwnPublish(earlier)
      ..recordOwnPublish(aPublishedAt);
    guard.recordSuperseded(SupersededSosEvidence(closedAt: closedAt));
    final restored = SosStopGuard()..restoreFromJson(guard.toJson());
    expect(restored.isSupersededOccurrence(earlier), isTrue);
    expect(restored.isSupersededOccurrence(aPublishedAt), isTrue);
    expect(restored.isSupersededOccurrence(closedAt), isFalse);
    restored.recordOwnPublish(bPublishedAt);
    expect(
      restored.isSupersededOccurrence(bPublishedAt),
      isFalse,
      reason: 'published after the close: the current SOS',
    );
  });

  // r7 MEDIUM-1: the backend merged B into A's still-open incident. B's exact
  // publish timestamp proves the incident is B's: the id stops being A's.
  test('the current SOS\'s exact occurredAt beats a superseded incident id '
      '(merged incident): allowed and the id is the current SOS\'s from then '
      'on, also after a restart', () {
    final guard = guardWithA();
    expect(
      allowed(
        guard,
        SosStopBasis.exactOccurredAt,
        incidentId: 'incident-a',
        occurredAt: bPublishedAt,
        currentPublishedAt: bPublishedAt,
      ),
      isTrue,
    );
    expect(guard.isSupersededIncident('incident-a'), isFalse);
    expect(
      allowed(guard, SosStopBasis.exactIncident, incidentId: 'incident-a'),
      isTrue,
    );
    guard.learnSupersededIncidentId('incident-a', aPublishedAt);
    expect(
      guard.isSupersededIncident('incident-a'),
      isFalse,
      reason: 'a late A event never takes the merged id back',
    );
    final restored = SosStopGuard()..restoreFromJson(guard.toJson());
    expect(restored.isSupersededIncident('incident-a'), isFalse);
    expect(restored.isSupersededOccurrence(aPublishedAt), isTrue);
    expect(
      lines.any((l) => l.contains('incident-a')),
      isFalse,
      reason: 'ids never logged',
    );
  });

  test('reassignToCurrent needs the exact current publish timestamp', () {
    final guard = guardWithA();
    expect(
      guard.reassignToCurrent(
        incidentId: 'incident-a',
        occurredAt: aPublishedAt,
        currentPublishedAt: aPublishedAt,
        source: 'test',
      ),
      isFalse,
      reason: 'A\'s own timestamp is never the current SOS\'s',
    );
    expect(
      guard.reassignToCurrent(
        incidentId: 'incident-a',
        occurredAt: bPublishedAt.add(const Duration(milliseconds: 1)),
        currentPublishedAt: bPublishedAt,
        source: 'test',
      ),
      isFalse,
    );
    expect(guard.isSupersededIncident('incident-a'), isTrue);
    expect(
      guard.reassignToCurrent(
        incidentId: 'incident-a',
        occurredAt: bPublishedAt,
        currentPublishedAt: bPublishedAt,
        source: 'test',
      ),
      isTrue,
    );
    expect(guard.isSupersededIncident('incident-a'), isFalse);
    // B is later closed by the TAG and superseded in turn: the id is B's
    // superseded evidence again.
    guard.recordSuperseded(
      SupersededSosEvidence(
        closedAt: bPublishedAt.add(const Duration(minutes: 1)),
        publishedAt: bPublishedAt,
        incidentIds: const <String>['incident-a'],
      ),
    );
    expect(guard.isSupersededIncident('incident-a'), isTrue);
  });

  // F13 (device cases 12/13, Roger 18/11/2026): a stop that could not be
  // written then is never written on its own when a link or writer comes
  // back, whatever identity it carries.
  test('a deferred replay is always refused and logged', () {
    for (final kind in <SosStopKind>[
      SosStopKind.tagStop,
      SosStopKind.nativeCycleClose,
    ]) {
      for (final incidentId in <String?>[null, 'incident-b']) {
        final decision = SosStopGuard().authorize(
          SosStopRequest(
            kind: kind,
            basis: SosStopBasis.deferredReplay,
            source: 'test_reconnect',
            incidentId: incidentId,
            nativeCycleId: 'cycle-b',
          ),
        );
        expect(decision.allowed, isFalse, reason: '${kind.name} $incidentId');
        expect(decision.reason, 'deferred_replay_unclassified');
      }
    }
    expect(
      lines.where(
        (line) =>
            line.contains('SOS_OUTBOX_STOP_GUARD_REFUSED') &&
            line.contains('basis=deferredReplay') &&
            line.contains('source=test_reconnect') &&
            line.contains('action=keep_sos_active'),
      ),
      hasLength(4),
    );
    // The user's own action and the prompt's owed stop stay allowed.
    expect(allowed(SosStopGuard(), SosStopBasis.userAction), isTrue);
    expect(allowed(SosStopGuard(), SosStopBasis.owedStop), isTrue);
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
