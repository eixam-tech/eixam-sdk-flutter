import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/services.dart';

class PhoneRadioPlatformProbe {
  const PhoneRadioPlatformProbe({
    MethodChannel? methodChannel,
    this.timeout = const Duration(seconds: 2),
  }) : _methodChannel =
           methodChannel ?? const MethodChannel(_methodChannelName);

  static const String _methodChannelName =
      'dev.eixam.connect_flutter/phone_radio/methods';

  final MethodChannel _methodChannel;

  /// Bounds a stuck platform read so the telemetry loop keeps publishing.
  final Duration timeout;

  Future<SdkPhoneRadioReading?> read() async {
    try {
      final raw = await _methodChannel
          .invokeMapMethod<dynamic, dynamic>('readPhoneRadio')
          .timeout(timeout);
      if (raw == null) {
        return null;
      }
      return SdkPhoneRadioReading.fromJson(raw);
    } catch (_) {
      return null;
    }
  }
}
