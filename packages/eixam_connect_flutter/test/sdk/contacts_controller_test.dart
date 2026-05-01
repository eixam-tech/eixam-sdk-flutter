import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/contacts_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('initialize replaces the previous contacts subscription', () async {
    final sdk = _FakeContactsSdk();
    final controller = ContactsController(sdk: sdk);
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.initialize();

    expect(sdk.watchListenCount, 2);
    expect(sdk.watchCancelCount, 1);
  });
}

final class _FakeContactsSdk implements EixamConnectSdk {
  int watchListenCount = 0;
  int watchCancelCount = 0;

  @override
  Future<List<EmergencyContact>> listEmergencyContacts() async =>
      const <EmergencyContact>[];

  @override
  Stream<List<EmergencyContact>> watchEmergencyContacts() {
    late final StreamController<List<EmergencyContact>> controller;
    controller = StreamController<List<EmergencyContact>>(
      onListen: () {
        watchListenCount++;
      },
      onCancel: () {
        watchCancelCount++;
        return controller.close();
      },
    );
    return controller.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
