import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Invalid-handle-compatible notification failure. The native plugin preserves
/// operation/platform/code but drops NSError's domain. Never apply this without
/// verified post-migration identity and a connected Eixam runtime. Descriptions
/// are localized, so consumer language must not control recovery detection.
bool isIosStaleGattError(Object error) =>
    error is FlutterBluePlusException &&
    error.platform == ErrorPlatform.apple &&
    error.function == 'setNotifyValue' &&
    error.code == 1;
