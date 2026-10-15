import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production iOS snapshot parser preserves backend-resolved E3',
    () async {
      if (!Platform.isMacOS) return;
      final source = File(
        'ios/Classes/ProtectionRuntimeBridge.swift',
      ).readAsStringSync();
      final kinds = source.substring(
        source.indexOf('  private enum IosBleSosSnapshotKind:'),
        source.indexOf('  private var eventSink:'),
      );
      final parser = source.substring(
        source.indexOf('  private func parseIosBleSosSnapshot('),
        source.indexOf(
          '  func peripheral(_ peripheral: CBPeripheral, didWrite',
        ),
      );
      final root = Directory.systemTemp.createTempSync('ios-sos-snapshot-');
      addTearDown(() => root.deleteSync(recursive: true));
      final main = File('${root.path}/main.swift');
      main.writeAsStringSync(
        'import Foundation\nfinal class Parser {\n$kinds\n$parser\n' +
            r'''
  func verify() {
    let node: [UInt8] = [0x6e, 0x75, 0x93, 0x55]
    for subcode: UInt8 in [0, 2] {
      guard let resolved = parseIosBleSosSnapshot(bytes: [0xe3, subcode] + node, receivedAt: 1000) else {
        fatalError("backend-resolved E3 was dropped before native lifecycle delivery")
      }
      precondition(resolved.kind.rawValue == "resolved", "E3 must not become user cancellation")
      precondition(resolved.nodeId == 1435727214)
      precondition(resolved.packetId == nil && resolved.deadlineAt == nil)
    }
    for opcode: UInt8 in [0xe1, 0xe2] {
      let terminal = parseIosBleSosSnapshot(bytes: [opcode, 1] + node, receivedAt: 1000)
      precondition(terminal?.kind.rawValue == "cancelled")
      precondition(terminal?.nodeId == 1435727214)
    }
    let countdown = parseIosBleSosSnapshot(bytes: node + [0x02, 0x40, 0], receivedAt: 1000)
    precondition(countdown?.kind.rawValue == "preSos" && countdown?.deadlineAt == 21000)
    let active = parseIosBleSosSnapshot(bytes: node + [0x02, 0xc0, 0], receivedAt: 1000)
    precondition(active?.kind.rawValue == "active" && active?.packetId == 2)
    precondition(parseIosBleSosSnapshot(bytes: [0xd0, 10, 0, 0, 0, 7, 8], receivedAt: 1000) == nil)
    precondition(parseIosBleSosSnapshot(bytes: [0xe3, 2, 0x6e], receivedAt: 1000) == nil)
    precondition(parseIosBleSosSnapshot(bytes: [0xe9, 0] + node, receivedAt: 1000) == nil)
  }
}
Parser().verify()
''',
      );
      final binary = '${root.path}/regression';
      final compile = await Process.run('swiftc', [
        'ios/Classes/TelAggregateReassembler.swift',
        main.path,
        '-o',
        binary,
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      final run = await Process.run(binary, []);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    },
  );
}
