import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'ios/Classes/BackgroundLocationBridge.swift',
  ).readAsStringSync();

  test('the native bridge owns exactly one CLLocationManager', () {
    expect('CLLocationManager()'.allMatches(source), hasLength(1));
  });

  test('global service status is queried only on the utility queue', () {
    expect(
      'CLLocationManager.locationServicesEnabled()'.allMatches(source),
      hasLength(1),
    );
    final refreshStart = source.indexOf(
      'private func refreshLocationServicesStatus',
    );
    final refreshEnd = source.indexOf(
      'private func authorizationName',
      refreshStart,
    );
    final refreshBody = source.substring(refreshStart, refreshEnd);
    expect(
      refreshBody,
      contains('Self.locationServicesQueryQueue.async'),
    );
    expect(
      refreshBody,
      contains('CLLocationManager.locationServicesEnabled()'),
    );
    expect(
      refreshBody,
      contains(
        'locationServicesQueryShouldEmit =\n'
        '      locationServicesQueryShouldEmit || emit',
      ),
    );
    expect(
      refreshBody,
      contains('if changed || shouldEmit'),
    );
  });

  test('permission replay and native samples use cached permission state', () {
    final snapshotStart = source.indexOf('private func permissionSnapshot');
    final snapshotEnd = source.indexOf(
      'private func runtimeStatus',
      snapshotStart,
    );
    final snapshotBody = source.substring(snapshotStart, snapshotEnd);
    expect(snapshotBody, contains('cachedLocationServicesEnabled'));
    expect(snapshotBody, isNot(contains('locationServicesEnabled()')));

    final sampleStart = source.indexOf('func locationManager(\n    _ manager');
    final sampleEnd = source.indexOf(
      'func locationManagerDidChangeAuthorization',
      sampleStart,
    );
    final sampleCallbacks = source.substring(sampleStart, sampleEnd);
    expect(
      sampleCallbacks,
      isNot(contains('CLLocationManager.locationServicesEnabled()')),
    );
    expect(
        source, contains('observer(runtimeStatus(sampleAction: "replayed"))'));
  });

  test('active tracking waits for the first service-status result', () {
    final reconcileStart = source.indexOf('private func reconcileRuntime');
    final reconcileEnd = source.indexOf(
      'private func startLocationManager',
      reconcileStart,
    );
    final reconcileBody = source.substring(reconcileStart, reconcileEnd);
    final unknownGuard = reconcileBody.indexOf(
      'guard locationServicesStatusKnown else',
    );
    final disabledGuard = reconcileBody.indexOf(
      'guard cachedLocationServicesEnabled else',
    );

    expect(unknownGuard, greaterThanOrEqualTo(0));
    expect(disabledGuard, greaterThan(unknownGuard));
    expect(
      reconcileBody.substring(unknownGuard, disabledGuard),
      contains('refreshLocationServicesStatus(emit: emit)'),
    );
  });

  test('observers retain an emit request while the first query is in flight',
      () {
    final observerStart = source.indexOf('func addObserver');
    final observerEnd = source.indexOf('func removeObserver', observerStart);
    final observerBody = source.substring(observerStart, observerEnd);

    expect(observerBody, contains('observers[token] = observer'));
    expect(observerBody, contains('if !locationServicesStatusKnown'));
    expect(observerBody, contains('refreshLocationServicesStatus(emit: true)'));
    expect(
      source,
      contains(
        'locationServicesQueryShouldEmit =\n'
        '      locationServicesQueryShouldEmit || emit',
      ),
    );
  });

  test('authorization delegates update the manager-backed cache', () {
    expect(
      source,
      contains('cachedAuthorizationStatus = manager.authorizationStatus'),
    );
    expect(source, contains('cachedAuthorizationStatus = status'));
    expect(
      source,
      contains(
          '"authorization": authorizationName(currentAuthorizationStatus())'),
    );
  });
}
