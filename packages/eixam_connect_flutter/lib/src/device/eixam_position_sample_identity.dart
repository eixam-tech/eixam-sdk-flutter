import 'package:crypto/crypto.dart';

abstract final class EixamPositionSampleIdentity {
  static String liveRecord(List<int> record) =>
      'tlb1:${sha256.convert(record)}';

  static String classicTel(List<int> wire) => 'tlt1:${sha256.convert(wire)}';

  static String telWireFingerprint(List<int> wire) =>
      sha256.convert(wire).toString();
}
