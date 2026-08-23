import 'sdk_resolved_location.dart';

enum EixamDevicePositionDelivery { live, recovered }

/// One real position sample captured by a connected EIXAM device.
///
/// [sampledAt] is present only when the device-provided timestamp is plausible
/// UTC. [stableSampleKey] is an opaque replay/idempotency key; applications
/// should compare it, not parse it.
class EixamDevicePositionSample {
  const EixamDevicePositionSample({
    required this.latitude,
    required this.longitude,
    required this.altitudeMeters,
    required this.sampledAt,
    required this.packetId,
    required this.source,
    required this.stableSampleKey,
  });

  final double latitude;
  final double longitude;
  final double? altitudeMeters;
  final DateTime? sampledAt;
  bool get timestampValid => sampledAt != null;
  final int packetId;
  final SdkLocationSource source;
  final String stableSampleKey;
}

/// A live BLE delivery of device position samples in firmware order.
///
/// Samples are oldest to newest. [receivedAt] is the phone/SDK reception time,
/// and is distinct from each device-provided [EixamDevicePositionSample.sampledAt].
class EixamDevicePositionBatch {
  EixamDevicePositionBatch({
    required List<EixamDevicePositionSample> samples,
    required this.receivedAt,
    required this.source,
    this.delivery = EixamDevicePositionDelivery.live,
    this.deviceIdentity,
  }) : samples = List<EixamDevicePositionSample>.unmodifiable(samples);

  final List<EixamDevicePositionSample> samples;
  final DateTime receivedAt;
  final SdkLocationSource source;
  final EixamDevicePositionDelivery delivery;

  /// Stable opaque identity of the TAG that produced this batch.
  ///
  /// Consumers may compare this value with the connected device's canonical
  /// identity. They must not parse it or treat it as a BLE address.
  final String? deviceIdentity;
}
