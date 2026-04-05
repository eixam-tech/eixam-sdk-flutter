import 'package:flutter/foundation.dart';

import 'android_protection_platform_adapter.dart';
import 'ios_protection_platform_adapter.dart';
import 'protection_platform_adapter.dart';

ProtectionPlatformAdapter buildDefaultProtectionPlatformAdapter() {
  if (kIsWeb) {
    return const NoopProtectionPlatformAdapter();
  }

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return AndroidProtectionPlatformAdapter();
    case TargetPlatform.iOS:
      return IosProtectionPlatformAdapter();
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return const NoopProtectionPlatformAdapter();
  }
}
