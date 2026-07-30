import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  const usableWhenInUse = LocationPermissionSnapshot(
    locationServicesEnabled: true,
    authorizationStatus: LocationAuthorizationStatus.whenInUse,
    accuracyAuthorization: LocationAccuracyAuthorization.full,
  );

  group('resolveBackgroundLocationMode', () {
    const cases = <(
      List<BackgroundLocationContext>,
      BackgroundLocationMode,
    )>[
      (<BackgroundLocationContext>[], BackgroundLocationMode.idle),
      (
        <BackgroundLocationContext>[BackgroundLocationContext.sharing],
        BackgroundLocationMode.sharing,
      ),
      (
        <BackgroundLocationContext>[BackgroundLocationContext.dmp],
        BackgroundLocationMode.dmp,
      ),
      (
        <BackgroundLocationContext>[BackgroundLocationContext.sos],
        BackgroundLocationMode.sos,
      ),
      (
        <BackgroundLocationContext>[
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.dmp,
        ],
        BackgroundLocationMode.dmp,
      ),
      (
        <BackgroundLocationContext>[
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.sos,
        ],
        BackgroundLocationMode.sos,
      ),
      (
        <BackgroundLocationContext>[
          BackgroundLocationContext.dmp,
          BackgroundLocationContext.sos,
        ],
        BackgroundLocationMode.sos,
      ),
      (
        <BackgroundLocationContext>[
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.dmp,
          BackgroundLocationContext.sos,
        ],
        BackgroundLocationMode.sos,
      ),
    ];

    for (final (contexts, expected) in cases) {
      test('$contexts resolves to $expected', () {
        expect(resolveBackgroundLocationMode(contexts), expected);
      });
    }

    test('input order does not affect priority', () {
      final modes = <BackgroundLocationMode>{
        resolveBackgroundLocationMode(const <BackgroundLocationContext>[
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.dmp,
          BackgroundLocationContext.sos,
        ]),
        resolveBackgroundLocationMode(const <BackgroundLocationContext>[
          BackgroundLocationContext.sos,
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.dmp,
        ]),
        resolveBackgroundLocationMode(const <BackgroundLocationContext>[
          BackgroundLocationContext.dmp,
          BackgroundLocationContext.sos,
          BackgroundLocationContext.sharing,
        ]),
      };

      expect(modes, <BackgroundLocationMode>{BackgroundLocationMode.sos});
    });

    test('duplicate input values do not affect priority', () {
      expect(
        resolveBackgroundLocationMode(const <BackgroundLocationContext>[
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.dmp,
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.dmp,
        ]),
        BackgroundLocationMode.dmp,
      );
    });

    test('removing a context reveals the highest remaining context', () {
      final contexts = <BackgroundLocationContext>{
        BackgroundLocationContext.sharing,
        BackgroundLocationContext.sos,
      };
      expect(
          resolveBackgroundLocationMode(contexts), BackgroundLocationMode.sos);

      contexts.remove(BackgroundLocationContext.sos);
      expect(
        resolveBackgroundLocationMode(contexts),
        BackgroundLocationMode.sharing,
      );
    });

    test('lower-priority removal does not suppress DMP or SOS', () {
      expect(
        resolveBackgroundLocationMode(const <BackgroundLocationContext>[
          BackgroundLocationContext.dmp,
        ]),
        BackgroundLocationMode.dmp,
      );
      expect(
        resolveBackgroundLocationMode(const <BackgroundLocationContext>[
          BackgroundLocationContext.sos,
        ]),
        BackgroundLocationMode.sos,
      );
    });
  });

  group('LocationPermissionSnapshot', () {
    test('services disabled requires Settings recovery', () {
      const snapshot = LocationPermissionSnapshot(
        locationServicesEnabled: false,
        authorizationStatus: LocationAuthorizationStatus.always,
        accuracyAuthorization: LocationAccuracyAuthorization.full,
      );

      expect(snapshot.isForegroundLocationUsable, isFalse);
      expect(snapshot.isBackgroundLocationUsable, isFalse);
      expect(snapshot.canAttemptWhenInUsePrompt, isFalse);
      expect(snapshot.canAttemptAlwaysUpgrade, isFalse);
      expect(snapshot.requiresSettingsRecovery, isTrue);
    });

    test('not determined permits a When-In-Use prompt attempt', () {
      const snapshot = LocationPermissionSnapshot(
        locationServicesEnabled: true,
        authorizationStatus: LocationAuthorizationStatus.notDetermined,
        accuracyAuthorization: LocationAccuracyAuthorization.unknown,
      );

      expect(snapshot.isForegroundLocationUsable, isFalse);
      expect(snapshot.isBackgroundLocationUsable, isFalse);
      expect(snapshot.canAttemptWhenInUsePrompt, isTrue);
      expect(snapshot.canAttemptAlwaysUpgrade, isFalse);
      expect(snapshot.requiresSettingsRecovery, isFalse);
    });

    for (final status in const <LocationAuthorizationStatus>[
      LocationAuthorizationStatus.denied,
      LocationAuthorizationStatus.restricted,
    ]) {
      test('$status requires Settings recovery', () {
        final snapshot = LocationPermissionSnapshot(
          locationServicesEnabled: true,
          authorizationStatus: status,
          accuracyAuthorization: LocationAccuracyAuthorization.unknown,
        );

        expect(snapshot.isForegroundLocationUsable, isFalse);
        expect(snapshot.isBackgroundLocationUsable, isFalse);
        expect(snapshot.canAttemptWhenInUsePrompt, isFalse);
        expect(snapshot.canAttemptAlwaysUpgrade, isFalse);
        expect(snapshot.requiresSettingsRecovery, isTrue);
      });
    }

    test('When In Use is foreground-ready and permits an Always attempt', () {
      expect(usableWhenInUse.isForegroundLocationUsable, isTrue);
      expect(usableWhenInUse.isBackgroundLocationUsable, isFalse);
      expect(usableWhenInUse.canAttemptWhenInUsePrompt, isFalse);
      expect(usableWhenInUse.canAttemptAlwaysUpgrade, isTrue);
      expect(usableWhenInUse.requiresSettingsRecovery, isFalse);
    });

    test('Always is foreground- and background-ready', () {
      const snapshot = LocationPermissionSnapshot(
        locationServicesEnabled: true,
        authorizationStatus: LocationAuthorizationStatus.always,
        accuracyAuthorization: LocationAccuracyAuthorization.reduced,
      );

      expect(snapshot.isForegroundLocationUsable, isTrue);
      expect(snapshot.isBackgroundLocationUsable, isTrue);
      expect(snapshot.canAttemptWhenInUsePrompt, isFalse);
      expect(snapshot.canAttemptAlwaysUpgrade, isFalse);
      expect(snapshot.requiresSettingsRecovery, isFalse);
      expect(
        snapshot.accuracyAuthorization,
        LocationAccuracyAuthorization.reduced,
      );
    });

    test('reduced and full accuracy remain explicitly distinguishable', () {
      final reduced = usableWhenInUse.copyWith(
        accuracyAuthorization: LocationAccuracyAuthorization.reduced,
      );
      final full = reduced.copyWith(
        accuracyAuthorization: LocationAccuracyAuthorization.full,
      );

      expect(
        reduced.accuracyAuthorization,
        LocationAccuracyAuthorization.reduced,
      );
      expect(
        full.accuracyAuthorization,
        LocationAccuracyAuthorization.full,
      );
      expect(full, usableWhenInUse);
      expect(full.hashCode, usableWhenInUse.hashCode);
    });
  });

  group('BackgroundLocationRuntimeStatus', () {
    BackgroundLocationRuntimeStatus status({
      Iterable<BackgroundLocationContext> contexts =
          const <BackgroundLocationContext>[],
      bool supported = true,
      bool running = false,
      DateTime? lastAcceptedLocationAt,
      String? lastErrorCode,
      String? lastErrorMessage,
      bool restored = false,
    }) {
      return BackgroundLocationRuntimeStatus(
        activeContexts: contexts,
        isNativePlatformSupported: supported,
        isNativeServiceRunning: running,
        permission: usableWhenInUse,
        lastAcceptedLocationAt: lastAcceptedLocationAt,
        lastErrorCode: lastErrorCode,
        lastErrorMessage: lastErrorMessage,
        wasRestoredAfterRelaunch: restored,
      );
    }

    test('copies and externally protects active contexts', () {
      final source = <BackgroundLocationContext>{
        BackgroundLocationContext.sharing,
      };
      final snapshot = status(contexts: source);
      source.add(BackgroundLocationContext.sos);

      expect(
        snapshot.activeContexts,
        <BackgroundLocationContext>{BackgroundLocationContext.sharing},
      );
      expect(
        () => snapshot.activeContexts.add(BackgroundLocationContext.dmp),
        throwsUnsupportedError,
      );
    });

    test('derives idle, sharing, DMP, and SOS modes', () {
      expect(status().effectiveMode, BackgroundLocationMode.idle);
      expect(
        status(contexts: const [BackgroundLocationContext.sharing])
            .effectiveMode,
        BackgroundLocationMode.sharing,
      );
      expect(
        status(contexts: const [BackgroundLocationContext.dmp]).effectiveMode,
        BackgroundLocationMode.dmp,
      );
      expect(
        status(contexts: const [BackgroundLocationContext.sos]).effectiveMode,
        BackgroundLocationMode.sos,
      );
    });

    test('effective mode remains derived after copyWith', () {
      final sharing = status(
        contexts: const <BackgroundLocationContext>[
          BackgroundLocationContext.sharing,
        ],
      );
      final sos = sharing.copyWith(
        activeContexts: const <BackgroundLocationContext>[
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.sos,
        ],
      );

      expect(sharing.effectiveMode, BackgroundLocationMode.sharing);
      expect(sos.effectiveMode, BackgroundLocationMode.sos);
    });

    test('represents unsupported, stopped, and running platforms', () {
      final unsupported = status(supported: false);
      final stopped = status(supported: true);
      final running = status(supported: true, running: true);

      expect(unsupported.isNativePlatformSupported, isFalse);
      expect(unsupported.isNativeServiceRunning, isFalse);
      expect(stopped.isNativePlatformSupported, isTrue);
      expect(stopped.isNativeServiceRunning, isFalse);
      expect(running.isNativePlatformSupported, isTrue);
      expect(running.isNativeServiceRunning, isTrue);
    });

    test('represents restored state, timestamp, and errors', () {
      final timestamp = DateTime.utc(2026, 7, 24, 12);
      final snapshot = status(
        lastAcceptedLocationAt: timestamp,
        lastErrorCode: 'location_unavailable',
        lastErrorMessage: 'No accepted location is currently available.',
        restored: true,
      );

      expect(snapshot.lastAcceptedLocationAt, timestamp);
      expect(snapshot.lastErrorCode, 'location_unavailable');
      expect(
        snapshot.lastErrorMessage,
        'No accepted location is currently available.',
      );
      expect(snapshot.wasRestoredAfterRelaunch, isTrue);
    });

    test('has value equality independent of context order', () {
      final left = status(
        contexts: const <BackgroundLocationContext>[
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.dmp,
        ],
      );
      final right = status(
        contexts: const <BackgroundLocationContext>[
          BackgroundLocationContext.dmp,
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.dmp,
        ],
      );

      expect(left, right);
      expect(left.hashCode, right.hashCode);
    });

    test('copyWith updates fields and can clear nullable fields', () {
      final timestamp = DateTime.utc(2026, 7, 24, 12);
      final initial = status(
        lastAcceptedLocationAt: timestamp,
        lastErrorCode: 'temporary',
        lastErrorMessage: 'Temporary error',
      );
      final updated = initial.copyWith(
        isNativeServiceRunning: true,
        lastAcceptedLocationAt: null,
        lastErrorCode: null,
        lastErrorMessage: null,
        wasRestoredAfterRelaunch: true,
      );

      expect(updated.isNativeServiceRunning, isTrue);
      expect(updated.lastAcceptedLocationAt, isNull);
      expect(updated.lastErrorCode, isNull);
      expect(updated.lastErrorMessage, isNull);
      expect(updated.wasRestoredAfterRelaunch, isTrue);
      expect(updated.activeContexts, initial.activeContexts);
      expect(updated.permission, initial.permission);
    });
  });
}
