import 'package:eixam_connect_flutter/src/tag_alerts/tag_drop_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 2, 12);

  DateTime resolve({bool disconnect = true, DateTime? at, DateTime? seen}) =>
      TagDropTime.resolve(
        now: now,
        nativeEventIsDisconnect: disconnect,
        nativeEventAt: at,
        lastSeenConnectedAt: seen,
      );

  test('a late-delivered native drop counts from its own timestamp', () {
    final at = now.subtract(const Duration(minutes: 40));
    expect(resolve(at: at, seen: at.subtract(const Duration(minutes: 1))), at);
    expect(resolve(at: at), at, reason: 'never seen connected by this run');
  });

  test('anything not clearly this drop counts from now', () {
    final at = now.subtract(const Duration(minutes: 40));
    expect(resolve(disconnect: false, at: at), now);
    expect(resolve(), now);
    expect(resolve(at: now.add(const Duration(seconds: 1))), now);
    expect(resolve(at: now.subtract(const Duration(hours: 25))), now);
  });

  test('an event older than the last time the link was seen up is stale', () {
    final seen = now.subtract(const Duration(minutes: 5));
    expect(resolve(at: seen, seen: seen), now);
    expect(
      resolve(at: seen.subtract(const Duration(minutes: 30)), seen: seen),
      now,
    );
    expect(
      resolve(at: seen.add(const Duration(seconds: 3)), seen: seen),
      seen.add(const Duration(seconds: 3)),
    );
  });
}
