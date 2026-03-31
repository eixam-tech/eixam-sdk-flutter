import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/repositories/telemetry_repository.dart';
import '../device/ble_debug_registry.dart';
import '../device/ble_incoming_event.dart';
import '../device/device_sos_controller.dart';

class BleOperationalRuntimeBridge {
  BleOperationalRuntimeBridge({
    required Stream<BleIncomingEvent> bleIncomingEvents,
    required Stream<RealtimeEvent> realtimeEvents,
    required this.telemetryRepository,
    required this.sosRepository,
    required this.deviceSosController,
    DateTime Function()? now,
    Duration dedupWindow = const Duration(seconds: 3),
  })  : _bleIncomingEvents = bleIncomingEvents,
        _realtimeEvents = realtimeEvents,
        _now = now ?? DateTime.now,
        _dedupWindow = dedupWindow;

  final Stream<BleIncomingEvent> _bleIncomingEvents;
  final Stream<RealtimeEvent> _realtimeEvents;
  final TelemetryRepository telemetryRepository;
  final SosRepository sosRepository;
  final DeviceSosController deviceSosController;
  final DateTime Function() _now;
  final Duration _dedupWindow;

  final Map<String, DateTime> _recentTelemetrySignatures = <String, DateTime>{};
  final Map<String, DateTime> _recentSosSignatures = <String, DateTime>{};
  final Map<String, DateTime> _recentConfirmationSignatures =
      <String, DateTime>{};

  StreamSubscription<BleIncomingEvent>? _bleSub;
  StreamSubscription<RealtimeEvent>? _realtimeSub;
  bool _started = false;

  void start() {
    if (_started) {
      return;
    }
    _started = true;
    _bleSub = _bleIncomingEvents.listen(
      (event) => unawaited(_handleBleIncomingEvent(event)),
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'BLE operational bridge incoming-event error: $error',
        );
      },
    );
    _realtimeSub = _realtimeEvents.listen(
      (event) => unawaited(_handleRealtimeEvent(event)),
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'BLE operational bridge realtime-event error: $error',
        );
      },
    );
  }

  Future<void> dispose() async {
    await _bleSub?.cancel();
    await _realtimeSub?.cancel();
  }

  Future<void> _handleBleIncomingEvent(BleIncomingEvent event) async {
    switch (event.type) {
      case BleIncomingEventType.telPosition:
        await _publishTelemetryIfValid(event);
        return;
      case BleIncomingEventType.sosMeshPacket:
        await _publishSosIfValid(event);
        return;
      case BleIncomingEventType.telAggregateFragment:
      case BleIncomingEventType.telAggregateComplete:
      case BleIncomingEventType.guidedRescueStatus:
      case BleIncomingEventType.sosDeviceEvent:
      case BleIncomingEventType.unknownProtocolPacket:
        return;
    }
  }

  Future<void> _publishTelemetryIfValid(BleIncomingEvent event) async {
    final packet = event.telPacket;
    if (packet == null) {
      return;
    }

    final payload = SdkTelemetryPayload(
      timestamp: event.receivedAt.toUtc(),
      latitude: packet.position.latitude,
      longitude: packet.position.longitude,
      altitude: packet.position.altitudeMeters.toDouble(),
      deviceId: event.deviceId,
      deviceBattery: DeviceBatteryLevel.fromProtocolValue(packet.batteryLevel)
          ?.approximatePercentage
          ?.toDouble(),
    );
    if (!_hasMinimumTelemetry(payload)) {
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge skipped telemetry publish -> reason=minimum_fields_missing deviceId=${event.deviceId}',
      );
      return;
    }

    final signature = 'tel:${event.deviceId}:${packet.rawHex}';
    if (!_registerSignature(_recentTelemetrySignatures, signature)) {
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge skipped telemetry publish -> reason=duplicate signature=$signature',
      );
      return;
    }

    try {
      await telemetryRepository.publishTelemetry(payload);
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge published telemetry -> deviceId=${event.deviceId} signature=$signature',
      );
    } on EixamSdkException catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge telemetry publish rejected -> code=${error.code} message=${error.message}',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge telemetry publish failed -> error=$error',
      );
    }
  }

  Future<void> _publishSosIfValid(BleIncomingEvent event) async {
    final packet = event.sosPacket;
    final position = packet?.position;
    if (packet == null || position == null) {
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge skipped SOS publish -> reason=minimum_fields_missing deviceId=${event.deviceId}',
      );
      return;
    }

    final signature = 'sos:${event.deviceId}:${packet.rawHex}';
    if (!_registerSignature(_recentSosSignatures, signature)) {
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge skipped SOS publish -> reason=duplicate signature=$signature',
      );
      return;
    }

    try {
      await sosRepository.triggerSos(
        message: 'BLE SOS received from runtime device ${event.deviceId}',
        triggerSource: 'ble_device_runtime',
        positionSnapshot: TrackingPosition(
          latitude: position.latitude,
          longitude: position.longitude,
          altitude: position.altitudeMeters.toDouble(),
          timestamp: event.receivedAt.toUtc(),
          source: DeliveryMode.mesh,
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge published SOS -> deviceId=${event.deviceId} signature=$signature relayCount=${packet.relayCount}',
      );
    } on SosException catch (error) {
      if (error.code == 'E_SOS_ALREADY_ACTIVE') {
        BleDebugRegistry.instance.recordEvent(
          'BLE operational bridge skipped SOS publish -> reason=sos_already_active signature=$signature',
        );
        return;
      }
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge SOS publish rejected -> code=${error.code} message=${error.message}',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge SOS publish failed -> error=$error',
      );
    }
  }

  Future<void> _handleRealtimeEvent(RealtimeEvent event) async {
    final confirmation = _BleBackendConfirmation.fromRealtimeEvent(event);
    if (confirmation == null) {
      return;
    }

    final signature = confirmation.signature;
    if (!_registerSignature(_recentConfirmationSignatures, signature)) {
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge skipped backend confirmation -> reason=duplicate signature=$signature',
      );
      return;
    }

    try {
      switch (confirmation.kind) {
        case _BleBackendConfirmationKind.positionConfirmed:
          await deviceSosController.sendPositionConfirmed();
          break;
        case _BleBackendConfirmationKind.sosAcknowledged:
          await deviceSosController.acknowledgeSos();
          break;
        case _BleBackendConfirmationKind.sosRelayAcknowledged:
          final relayNodeId = confirmation.relayNodeId;
          if (relayNodeId == null) {
            return;
          }
          await deviceSosController.sendAckRelay(nodeId: relayNodeId);
          break;
      }
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge applied backend confirmation -> $signature',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge backend confirmation failed -> signature=$signature error=$error',
      );
    }
  }

  bool _hasMinimumTelemetry(SdkTelemetryPayload payload) {
    return payload.latitude.isFinite &&
        payload.latitude >= -90 &&
        payload.latitude <= 90 &&
        payload.longitude.isFinite &&
        payload.longitude >= -180 &&
        payload.longitude <= 180 &&
        payload.altitude.isFinite;
  }

  bool _registerSignature(
    Map<String, DateTime> recentSignatures,
    String signature,
  ) {
    final now = _now();
    recentSignatures.removeWhere(
      (_, seenAt) => now.difference(seenAt) > _dedupWindow,
    );
    if (recentSignatures.containsKey(signature)) {
      return false;
    }
    recentSignatures[signature] = now;
    return true;
  }
}

enum _BleBackendConfirmationKind {
  positionConfirmed,
  sosAcknowledged,
  sosRelayAcknowledged,
}

class _BleBackendConfirmation {
  const _BleBackendConfirmation({
    required this.kind,
    required this.signature,
    this.relayNodeId,
  });

  final _BleBackendConfirmationKind kind;
  final String signature;
  final int? relayNodeId;

  static _BleBackendConfirmation? fromRealtimeEvent(RealtimeEvent event) {
    final payload = event.payload;
    if (payload == null) {
      return null;
    }

    final type = _normalized(payload['type']);
    final status = _normalized(payload['status']);
    final action = _normalized(payload['action']);
    final command = _normalized(payload['command']);
    final ackType = _normalized(
      payload['ackType'] ?? payload['ack_type'] ?? payload['confirmationType'],
    );

    if (_matchesAny(
      <String?>[
        type,
        status,
        action,
        command,
      ],
      const <String>{
        'position_confirmed',
        'pos_confirmed',
        'telemetry_confirmed',
        'telemetry.acknowledged',
      },
    )) {
      return _BleBackendConfirmation(
        kind: _BleBackendConfirmationKind.positionConfirmed,
        signature: 'pos:${_signatureToken(payload)}',
      );
    }

    final relayNodeId = _relayNodeIdFrom(payload);
    final isRelayAck = ackType == 'relay' ||
        relayNodeId != null ||
        _matchesAny(
          <String?>[type, status, action, command],
          const <String>{'sos_ack_relay', 'sos.ack.relay'},
        );
    if (isRelayAck) {
      return _BleBackendConfirmation(
        kind: _BleBackendConfirmationKind.sosRelayAcknowledged,
        signature: 'relay:${relayNodeId ?? _signatureToken(payload)}',
        relayNodeId: relayNodeId,
      );
    }

    if (_matchesAny(
      <String?>[type, status, action, command],
      const <String>{
        'acknowledged',
        'sos_ack',
        'sos_acknowledged',
        'sos.acknowledged',
      },
    )) {
      return _BleBackendConfirmation(
        kind: _BleBackendConfirmationKind.sosAcknowledged,
        signature: 'ack:${_signatureToken(payload)}',
      );
    }

    return null;
  }

  static String _signatureToken(Map<String, dynamic> payload) {
    final value = payload['incidentId'] ??
        payload['id'] ??
        payload['timestamp'] ??
        payload['updatedAt'] ??
        payload['occurredAt'];
    return value?.toString() ?? 'event';
  }

  static int? _relayNodeIdFrom(Map<String, dynamic> payload) {
    final raw = payload['relayNodeId'] ??
        payload['relay_node_id'] ??
        payload['nodeId'] ??
        payload['node_id'];
    if (raw is int) {
      return raw;
    }
    if (raw is String) {
      return raw.startsWith('0x') || raw.startsWith('0X')
          ? int.tryParse(raw.substring(2), radix: 16)
          : int.tryParse(raw);
    }
    return null;
  }

  static String? _normalized(Object? value) {
    if (value is! String) {
      return null;
    }
    return value.trim().toLowerCase().replaceAll(' ', '_');
  }

  static bool _matchesAny(
    List<String?> values,
    Set<String> accepted,
  ) {
    for (final value in values) {
      if (value != null && accepted.contains(value)) {
        return true;
      }
    }
    return false;
  }
}
