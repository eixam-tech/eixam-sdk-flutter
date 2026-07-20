import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('SosIncidentProgress', () {
    test('does not confirm backend reception before backend evidence', () {
      final progress = _incident().progress;

      expect(
        progress.steps.single.state,
        SosProgressState.pending,
      );
    });

    test('backend incident confirms reception without actuator evidence', () {
      final progress = _incident(isBackendConfirmed: true).progress;

      expect(
        progress.steps.first.state,
        SosProgressState.succeeded,
      );
    });

    test('empty actuator snapshot confirms reception with no contact failure',
        () {
      final progress = _incident(
        isBackendConfirmed: true,
        actuators: const SosActuatorSnapshot(snapshotVersion: 0),
      ).progress;

      expect(progress.steps, hasLength(1));
      expect(progress.steps.single.state, SosProgressState.succeeded);
    });

    test('zero emergency contacts are not applicable rather than failed', () {
      final progress = _incident(
        isBackendConfirmed: true,
        actuators: _snapshot(status: 'skipped'),
      ).progress;

      expect(progress.steps.first.state, SosProgressState.succeeded);
      expect(progress.steps.last.state, SosProgressState.notApplicable);
      expect(progress.steps.last.totalTargets, 0);
    });

    test('incident remains received when every contact delivery fails', () {
      final progress = _incident(
        isBackendConfirmed: true,
        actuators: _snapshot(contactStatuses: const ['failed', 'failed']),
      ).progress;

      expect(progress.steps.first.state, SosProgressState.succeeded);
      expect(progress.steps.last.state, SosProgressState.failed);
    });

    test('duplicate retries count one stable contact and success wins', () {
      final progress = _incident(
        isBackendConfirmed: true,
        actuators: _snapshot(
          contacts: const <Map<String, dynamic>>[
            <String, dynamic>{
              'contactId': 'contact-1',
              'status': 'failed',
              'updatedAt': '2026-07-20T12:00:00Z',
            },
            <String, dynamic>{
              'contactId': 'contact-1',
              'status': 'delivered',
              'updatedAt': '2026-07-20T12:01:00Z',
            },
          ],
        ),
      ).progress;

      final contacts = progress.steps.last;
      expect(contacts.totalTargets, 1);
      expect(contacts.successfulTargets, 1);
      expect(contacts.failedTargets, 0);
      expect(contacts.state, SosProgressState.succeeded);
    });

    test('stale failed retry cannot regress delivered contact', () {
      final progress = _incident(
        isBackendConfirmed: true,
        actuators: _snapshot(
          contacts: const <Map<String, dynamic>>[
            <String, dynamic>{
              'contactId': 'contact-1',
              'status': 'delivered',
              'updatedAt': '2026-07-20T12:02:00Z',
            },
            <String, dynamic>{
              'contactId': 'contact-1',
              'status': 'no-answer',
              'updatedAt': '2026-07-20T12:01:00Z',
            },
          ],
        ),
      ).progress;

      expect(progress.steps.last.state, SosProgressState.succeeded);
    });

    test('provider lifecycle aliases follow the backend normalization', () {
      final snapshot = _snapshot(
        contacts: const <Map<String, dynamic>>[
          <String, dynamic>{'contactId': 'queued', 'status': 'queued'},
          <String, dynamic>{'contactId': 'ringing', 'status': 'ringing'},
          <String, dynamic>{'contactId': 'completed', 'status': 'completed'},
          <String, dynamic>{'contactId': 'busy', 'status': 'busy'},
        ],
      );

      expect(snapshot.items.single.contacts[0].status,
          SosActuatorStatus.scheduled);
      expect(snapshot.items.single.contacts[1].status, SosActuatorStatus.sent);
      expect(snapshot.items.single.contacts[2].status,
          SosActuatorStatus.delivered);
      expect(
          snapshot.items.single.contacts[3].status, SosActuatorStatus.failed);
    });

    test('sent contacts remain in progress rather than delivered', () {
      final progress = _incident(
        actuators: _snapshot(contactStatuses: const ['sent', 'sent']),
      ).progress;

      final contacts = progress.steps.last;
      expect(contacts.state, SosProgressState.inProgress);
      expect(contacts.successfulTargets, 0);
    });

    test('all delivered contacts are succeeded with trustworthy counts', () {
      final progress = _incident(
        actuators: _snapshot(contactStatuses: const ['delivered', 'delivered']),
      ).progress;

      final contacts = progress.steps.last;
      expect(contacts.state, SosProgressState.succeeded);
      expect(contacts.totalTargets, 2);
      expect(contacts.successfulTargets, 2);
      expect(contacts.failedTargets, 0);
    });

    test('mixed delivered and failed contacts are partial', () {
      final progress = _incident(
        actuators: _snapshot(contactStatuses: const ['delivered', 'failed']),
      ).progress;

      final contacts = progress.steps.last;
      expect(contacts.state, SosProgressState.partiallySucceeded);
      expect(contacts.successfulTargets, 1);
      expect(contacts.failedTargets, 1);
    });

    test('all failed contacts are failed', () {
      final progress = _incident(
        actuators: _snapshot(contactStatuses: const ['failed', 'failed']),
      ).progress;

      expect(progress.steps.last.state, SosProgressState.failed);
    });

    test('skipped contacts are not applicable', () {
      final progress = _incident(
        actuators: _snapshot(status: 'skipped'),
      ).progress;

      expect(progress.steps.last.state, SosProgressState.notApplicable);
    });

    test('unknown backend status maps safely to unknown', () {
      final progress = _incident(
        actuators: _snapshot(contactStatuses: const ['future-state']),
      ).progress;

      expect(progress.steps.last.state, SosProgressState.unknown);
    });

    test('restored incident marks progress as cached', () {
      final progress = _incident(
        actuators: _snapshot(),
        isUsingCachedData: true,
      ).progress;

      expect(progress.isUsingCachedData, isTrue);
    });
  });
}

SosIncident _incident({
  SosActuatorSnapshot? actuators,
  bool isBackendConfirmed = false,
  bool isUsingCachedData = false,
}) {
  return SosIncident(
    id: 'incident-1',
    state: SosState.sent,
    createdAt: DateTime.utc(2026, 7, 20),
    deliveryChannel: SosDeliveryChannel.backendOnly,
    actuators: actuators,
    isBackendConfirmed: isBackendConfirmed,
    isUsingCachedData: isUsingCachedData,
  );
}

SosActuatorSnapshot _snapshot({
  String status = 'scheduled',
  List<String> contactStatuses = const [],
  List<Map<String, dynamic>>? contacts,
}) {
  return SosActuatorSnapshot.fromJson(<String, dynamic>{
    'snapshotVersion': 3,
    'items': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'emergency_contacts',
        'type': 'emergency_contacts',
        'status': status,
        'outcome': status == 'failed' ? 'failure' : 'pending',
        'updatedAt': '2026-07-20T12:00:00Z',
        'contacts': contacts ??
            <Map<String, dynamic>>[
              for (var index = 0; index < contactStatuses.length; index++)
                <String, dynamic>{
                  'contactId': 'contact-$index',
                  'name': 'Contact $index',
                  'status': contactStatuses[index],
                  'channels': const <Map<String, dynamic>>[],
                },
            ],
      },
    ],
  });
}
