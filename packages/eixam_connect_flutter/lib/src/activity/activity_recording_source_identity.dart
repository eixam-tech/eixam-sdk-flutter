import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/canonical_hardware_id.dart';

/// Recording-only source grammar. Never changes global hardware identities.
final class ActivityRecordingSourceIdentity {
  const ActivityRecordingSourceIdentity._(this.value, this.nodeId);

  final String value;
  final int? nodeId;
  static final _nodeGrammar = RegExp(r'node:[1-9][0-9]{0,9}');

  static ActivityRecordingSourceIdentity? parse(String? raw) {
    if (raw == null) return null;
    if (raw.startsWith('node:')) {
      final match = _nodeGrammar.matchAsPrefix(raw);
      if (match == null || match.end != raw.length) return null;
      return forNode(int.tryParse(raw.substring(5)));
    }
    final mac = normalizeCanonicalHardwareId(raw);
    return mac == null ? null : ActivityRecordingSourceIdentity._(mac, null);
  }

  static ActivityRecordingSourceIdentity? forNode(int? nodeId) {
    // Existing operational node domain: u32 excluding unset and broadcast.
    if (nodeId == null || nodeId <= 0 || nodeId >= 0xffffffff) return null;
    return ActivityRecordingSourceIdentity._('node:$nodeId', nodeId);
  }

  static String? normalize(String? raw) => parse(raw)?.value;

  bool matchesDevice(DeviceStatus status) => nodeId != null
      ? status.nodeId == nodeId &&
            status.provisioningStatus == DeviceProvisioningStatus.provisioned
      : normalizeCanonicalHardwareId(status.canonicalHardwareId) == value;

  EixamDevicePositionBatch stamp(EixamDevicePositionBatch batch) =>
      EixamDevicePositionBatch(
        samples: batch.samples,
        receivedAt: batch.receivedAt,
        source: batch.source,
        delivery: batch.delivery,
        deviceIdentity: value,
      );
}
