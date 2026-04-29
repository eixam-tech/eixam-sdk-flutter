import 'package:flutter/foundation.dart';

import 'background_telemetry_platform_adapter.dart';

BackgroundTelemetryPlatformAdapter
    buildDefaultBackgroundTelemetryPlatformAdapter() {
  if (kIsWeb) {
    return const NoopBackgroundTelemetryPlatformAdapter();
  }

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return AndroidBackgroundTelemetryPlatformAdapter();
    case TargetPlatform.fuchsia:
    case TargetPlatform.iOS:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return const NoopBackgroundTelemetryPlatformAdapter();
  }
}
