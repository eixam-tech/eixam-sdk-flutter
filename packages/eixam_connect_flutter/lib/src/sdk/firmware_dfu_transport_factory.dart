import 'package:flutter/foundation.dart';

import 'firmware_dfu_transport.dart';
import 'platform_firmware_dfu_transport.dart';

FirmwareDfuTransport buildDefaultFirmwareDfuTransport() {
  if (kIsWeb) {
    return const UnsupportedFirmwareDfuTransport();
  }

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return PlatformFirmwareDfuTransport();
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return const UnsupportedFirmwareDfuTransport();
  }
}
