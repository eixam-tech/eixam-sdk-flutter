import 'package:eixam_connect_flutter/src/tag_alerts/tag_lease_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prints the tagged line outside release builds', () {
    final printed = <String?>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => printed.add(message);
    addTearDown(() => debugPrint = original);

    TagLeaseLog.write('scheduled kind=tagDisconnected');

    expect(kReleaseMode, isFalse);
    expect(printed, ['[TAG_LEASE] scheduled kind=tagDisconnected']);
  });
}
