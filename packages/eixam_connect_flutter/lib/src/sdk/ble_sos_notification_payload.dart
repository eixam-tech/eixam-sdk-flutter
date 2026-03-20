import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

class BleSosNotificationPayload {
  const BleSosNotificationPayload({
    required this.kind,
    required this.state,
    required this.transitionSource,
    this.deviceId,
    this.deviceAlias,
    this.nodeId,
  });

  final String kind;
  final DeviceSosState state;
  final DeviceSosTransitionSource transitionSource;
  final String? deviceId;
  final String? deviceAlias;
  final int? nodeId;

  String toJsonString() {
    return jsonEncode(<String, Object?>{
      'kind': kind,
      'state': state.name,
      'transitionSource': transitionSource.name,
      'deviceId': deviceId,
      'deviceAlias': deviceAlias,
      'nodeId': nodeId,
    });
  }

  static BleSosNotificationPayload? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final stateName = decoded['state'] as String?;
    final transitionSourceName = decoded['transitionSource'] as String?;
    final state = DeviceSosState.values.where(
      (value) => value.name == stateName,
    );
    final transitionSource = DeviceSosTransitionSource.values.where(
      (value) => value.name == transitionSourceName,
    );
    if (state.isEmpty) {
      return null;
    }

    return BleSosNotificationPayload(
      kind: (decoded['kind'] as String?) ?? 'incoming_sos',
      state: state.first,
      transitionSource: transitionSource.isEmpty
          ? DeviceSosTransitionSource.unknown
          : transitionSource.first,
      deviceId: decoded['deviceId'] as String?,
      deviceAlias: decoded['deviceAlias'] as String?,
      nodeId: decoded['nodeId'] as int?,
    );
  }
}
