import 'package:flutter/foundation.dart';

import 'background_location_platform_adapter.dart';

BackgroundLocationPlatformAdapter
    buildDefaultBackgroundLocationPlatformAdapter({
  TargetPlatform? platform,
  bool? isWeb,
}) {
  if (isWeb ?? kIsWeb) {
    return UnsupportedBackgroundLocationPlatformAdapter();
  }

  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.iOS:
      return IosBackgroundLocationPlatformAdapter();
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return UnsupportedBackgroundLocationPlatformAdapter();
  }
}
