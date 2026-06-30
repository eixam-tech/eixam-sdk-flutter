import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SDK library source does not throw raw StateError E_* codes', () {
    final violations = <String>[];
    for (final root in <String>[
      'lib',
      '../eixam_connect_core/lib',
    ]) {
      final directory = Directory(root);
      if (!directory.existsSync()) {
        continue;
      }
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        final source = entity.readAsStringSync();
        final match = RegExp(
          r'''throw\s+StateError\s*\(\s*['"]E_''',
          multiLine: true,
        ).firstMatch(source);
        if (match != null) {
          violations.add(entity.path);
        }
      }
    }

    expect(violations, isEmpty);
  });
}
