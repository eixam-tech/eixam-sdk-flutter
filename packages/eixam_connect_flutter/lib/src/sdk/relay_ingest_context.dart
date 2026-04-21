enum RelayIngestKind { telemetry, sos }

class RelayIngestContext {
  const RelayIngestContext({
    required this.kind,
    required this.remoteDeviceId,
    required this.gatewayRuntimeDeviceId,
    required this.payloadSignature,
    this.gatewayCanonicalHardwareId,
    this.relayCount,
  });

  final RelayIngestKind kind;
  final String remoteDeviceId;
  final String gatewayRuntimeDeviceId;
  final String payloadSignature;
  final String? gatewayCanonicalHardwareId;
  final int? relayCount;
}
