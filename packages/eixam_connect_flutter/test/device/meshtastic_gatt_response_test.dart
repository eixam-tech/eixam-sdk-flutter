import 'dart:async';

import 'package:eixam_connect_flutter/src/device/meshtastic_gatt_response.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bond cleanup response has a bounded deadline and disposes its listener',
    () async {
      final events = StreamController<int>.broadcast(sync: true);
      final request = MeshtasticGattResponse<int>(
        events.stream,
        timeout: const Duration(milliseconds: 5),
      );
      await expectLater(request.response, throwsA(isA<TimeoutException>()));
      await request.close();
      expect(events.hasListener, false);
      await events.close();
    },
  );

  test(
    'interrupt cancels the actual native response listener before return',
    () async {
      final events = StreamController<int>.broadcast(sync: true);
      final request = MeshtasticGattResponse<int>(events.stream);
      expect(events.hasListener, true);
      final checked = expectLater(request.response, throwsStateError);
      request.interrupt(StateError('disconnected'));
      await checked;
      await request.close();
      expect(events.hasListener, false);
      // A descriptor callback arriving later cannot complete this request again.
      events.add(105);
      await events.close();
    },
  );

  test('successful native response removes its listener', () async {
    final events = StreamController<int>.broadcast(sync: true);
    final request = MeshtasticGattResponse<int>(events.stream);
    events.add(105);
    expect(await request.response, 105);
    await request.close();
    expect(events.hasListener, false);
    await events.close();
  });

  test(
    'platform without CCCD callback still releases the response listener',
    () async {
      final events = StreamController<int>.broadcast(sync: true);
      final request = MeshtasticGattResponse<int>(events.stream);
      request.noResponseRequired();
      expect(await request.response, isNull);
      await request.close();
      expect(events.hasListener, false);
      await events.close();
    },
  );
}
