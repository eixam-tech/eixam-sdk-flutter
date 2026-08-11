import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('public core exports do not expose raw provisioning secrets', () {
    final barrel = File('lib/eixam_connect_core.dart');
    final source = barrel.readAsStringSync();
    final exportedPaths = RegExp(r"export '([^']+)';")
        .allMatches(source)
        .map((match) => match.group(1)!)
        .toList();
    final forbidden = RegExp(
      r'\bpsk\b|network_?psk|networkPsk|softSim|backendToken',
      caseSensitive: false,
    );

    for (final path in exportedPaths) {
      final exportedSource = File('lib/$path').readAsStringSync();
      expect(
        forbidden.hasMatch(exportedSource),
        isFalse,
        reason: 'Raw provisioning secret concept exposed by lib/$path',
      );
    }
  });
}
