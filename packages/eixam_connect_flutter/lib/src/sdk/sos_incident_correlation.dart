import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Conservative identity matching for backend evidence about an open SOS.
///
/// Missing identity never counts as a match. Explicit cycle/device conflicts
/// always win over an otherwise matching incident identifier.
bool sosIncidentEvidenceMatches(
  SosIncident current,
  SosIncident evidence,
) {
  if (_hasIncidentConflict(current, evidence)) return false;
  if (_ids(current).any(_ids(evidence).contains)) return true;
  return _sameNonEmpty(current.cycleKey, evidence.cycleKey);
}

bool sosIncidentEvidenceMatchesLifecycle(
  SosLifecycleSnapshot lifecycle,
  SosIncident evidence,
) {
  if (_hasLifecycleConflict(lifecycle, evidence)) return false;
  final lifecycleIds = <String>{
    if (_normalized(lifecycle.localIncidentId) case final id?) id,
    if (_normalized(lifecycle.backendIncidentId) case final id?) id,
    ..._ids(lifecycle.incident),
  };
  if (lifecycleIds.any(_ids(evidence).contains)) return true;
  return _sameNonEmpty(lifecycle.incident?.cycleKey, evidence.cycleKey);
}

bool _hasIncidentConflict(SosIncident current, SosIncident evidence) {
  if (_differentNonEmpty(current.cycleKey, evidence.cycleKey)) return true;
  if (_differentInt(current.originatorNodeId, evidence.originatorNodeId)) {
    return true;
  }
  if (_differentNonEmpty(current.deviceId, evidence.deviceId)) return true;
  if (_differentNonEmpty(current.hardwareId, evidence.hardwareId)) return true;
  return _differentCanonicalIds(current.id, evidence.id);
}

bool _hasLifecycleConflict(
  SosLifecycleSnapshot lifecycle,
  SosIncident evidence,
) {
  if (_differentNonEmpty(lifecycle.incident?.cycleKey, evidence.cycleKey)) {
    return true;
  }
  if (_differentInt(lifecycle.nodeId, evidence.originatorNodeId)) return true;
  if (_differentNonEmpty(lifecycle.deviceId, evidence.deviceId)) return true;
  if (_differentNonEmpty(lifecycle.hardwareId, evidence.hardwareId)) {
    return true;
  }
  if (lifecycle.incident != null &&
      _differentCanonicalIds(lifecycle.incident!.id, evidence.id)) {
    return true;
  }
  final backendId = _normalized(lifecycle.backendIncidentId);
  return backendId != null &&
      !_isProvisionalId(backendId) &&
      _differentCanonicalIds(backendId, evidence.id);
}

Set<String> _ids(SosIncident? incident) => <String>{
      if (_normalized(incident?.id) case final id?) id,
      if (_normalized(incident?.provisionalIncidentId) case final id?) id,
    };

bool _differentCanonicalIds(String left, String right) {
  final normalizedLeft = _normalized(left);
  final normalizedRight = _normalized(right);
  if (normalizedLeft == null || normalizedRight == null) return false;
  return !_isProvisionalId(normalizedLeft) &&
      !_isProvisionalId(normalizedRight) &&
      normalizedLeft != normalizedRight;
}

bool _isProvisionalId(String value) =>
    value.startsWith('sos-') || value.startsWith('device-runtime');

bool _sameNonEmpty(String? left, String? right) {
  final normalizedLeft = _normalized(left);
  return normalizedLeft != null && normalizedLeft == _normalized(right);
}

bool _differentNonEmpty(String? left, String? right) {
  final normalizedLeft = _normalized(left);
  final normalizedRight = _normalized(right);
  return normalizedLeft != null &&
      normalizedRight != null &&
      normalizedLeft != normalizedRight;
}

bool _differentInt(int? left, int? right) =>
    left != null && right != null && left != right;

String? _normalized(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
