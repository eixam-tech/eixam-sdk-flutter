import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production iOS snapshot parser preserves backend-resolved E3',
    () async {
      if (!Platform.isMacOS) return;
      final root = Directory.systemTemp.createTempSync('ios-sos-snapshot-');
      addTearDown(() => root.deleteSync(recursive: true));
      final main = File('${root.path}/main.swift');
      main.writeAsStringSync(r'''
import Foundation

func parse(_ bytes: [UInt8]) -> IosBleSosParsedSnapshot? {
  IosBleSosFrameClassifier.parse(bytes: bytes, characteristic: .tel, receivedAt: 1000)
}

func verify() {
  let node: [UInt8] = [0x6e, 0x75, 0x93, 0x55]
  for subcode: UInt8 in [0, 2] {
    guard let resolved = parse([0xe3, subcode] + node) else {
      fatalError("backend-resolved E3 was dropped before native lifecycle delivery")
    }
    precondition(resolved.kind.rawValue == "resolved", "E3 must not become user cancellation")
    precondition(resolved.nodeId == 1435727214)
    precondition(resolved.packetId == nil && resolved.deadlineAt == nil)
  }
  for opcode: UInt8 in [0xe1, 0xe2] {
    let terminal = parse([opcode, 1] + node)
    precondition(terminal?.kind.rawValue == "cancelled")
    precondition(terminal?.nodeId == 1435727214)
  }
  let countdown = parse(node + [0x02, 0x40, 0])
  precondition(countdown?.kind.rawValue == "preSos" && countdown?.deadlineAt == 21000)
  let active = parse(node + [0x02, 0xc0, 0])
  precondition(active?.kind.rawValue == "active" && active?.packetId == 2)
  precondition(parse([0xd0, 10, 0, 0, 0, 7, 8]) == nil)
  precondition(parse([0xe3, 2, 0x6e]) == nil)
  precondition(parse([0xe9, 0] + node) == nil)
}
verify()
''');
      final binary = '${root.path}/regression';
      final compile = await Process.run('swiftc', [
        'ios/Classes/IosBleSosFrameClassifier.swift',
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

  test(
    'iOS SOS frame classifier rejects non-SOS TEL frames (0xD3, 12 B bit 5)',
    () async {
      if (!Platform.isMacOS) return;
      final root = Directory.systemTemp.createTempSync('ios-sos-frames-');
      addTearDown(() => root.deleteSync(recursive: true));
      final binary = '${root.path}/frame_tests';
      final compile = await Process.run('swiftc', [
        '-parse-as-library',
        'ios/Classes/IosBleSosFrameClassifier.swift',
        'ios/Classes/TelAggregateReassembler.swift',
        'ios/Tests/IosBleSosFrameClassifierTests.swift',
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
      expect(run.stdout, contains('OK'));
    },
  );
}
