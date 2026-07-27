import 'package:eixam_connect_core/eixam_connect_core.dart';

enum PhonePositionSource {
  nativeContext,
  geolocator,
  oneShot,
}

abstract interface class LatestPhonePositionSink {
  TrackingPosition? get latestPhonePosition;

  Future<bool> acceptPhonePosition(
    TrackingPosition position, {
    required PhonePositionSource source,
  });
}
