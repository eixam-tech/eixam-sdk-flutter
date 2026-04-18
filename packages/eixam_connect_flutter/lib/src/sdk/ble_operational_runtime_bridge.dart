import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';

import '../data/repositories/telemetry_repository.dart';
import '../device/ble_debug_registry.dart';
import '../device/ble_incoming_event.dart';
import '../device/device_sos_controller.dart';
import '../device/eixam_ble_protocol.dart';
import '../device/eixam_sos_packet.dart';
import '../device/eixam_tel_packet.dart';

class BleOperationalRuntimeBridge {
  BleOperationalRuntimeBridge({
    required Stream<BleIncomingEvent> bleIncomingEvents,
    required Stream<RealtimeConnectionState> connectionStates,
    required Stream<RealtimeEvent> realtimeEvents,
    required this.telemetryRepository,
    required this.sosRepository,
    required this.deviceSosController,
    required EixamSession? Function() sessionProvider,
    Future<String?> Function(String runtimeDeviceId)? backendHardwareIdResolver,
    DateTime Function()? now,
    Duration dedupWindow = const Duration(seconds: 3),
  })  : _bleIncomingEvents = bleIncomingEvents,
        _connectionStates = connectionStates,
        _realtimeEvents = realtimeEvents,
        _sessionProvider = sessionProvider,
        _backendHardwareIdResolver = backendHardwareIdResolver,
        _now = now ?? DateTime.now,
        _dedupWindow = dedupWindow;

  final Stream<BleIncomingEvent> _bleIncomingEvents;
  final Stream<RealtimeConnectionState> _connectionStates;
  final Stream<RealtimeEvent> _realtimeEvents;
  final TelemetryRepository telemetryRepository;
  final SosRepository sosRepository;
  final DeviceSosController deviceSosController;
  final EixamSession? Function() _sessionProvider;
  final Future<String?> Function(String runtimeDeviceId)?
      _backendHardwareIdResolver;
  final DateTime Function() _now;
  final Duration _dedupWindow;

  final Map<String, DateTime> _recentTelemetrySignatures = <String, DateTime>{};
  final Map<String, DateTime> _recentSosSignatures = <String, DateTime>{};
  final Map<String, DateTime> _recentConfirmationSignatures =
      <String, DateTime>{};
  final StreamController<SdkBridgeDiagnostics> _diagnosticsController =
      StreamController<SdkBridgeDiagnostics>.broadcast();

  StreamSubscription<RealtimeConnectionState>? _connectionSub;
  StreamSubscription<BleIncomingEvent>? _bleSub;
  StreamSubscription<RealtimeEvent>? _realtimeSub;
  RealtimeConnectionState _connectionState =
      RealtimeConnectionState.disconnected;
  _PendingTelemetryPublish? _pendingTelemetry;
  _PendingSosPublish? _pendingSos;
  bool _flushInProgress = false;
  bool _started = false;
  SdkBridgeDiagnostics _diagnostics = const SdkBridgeDiagnostics();

  SdkBridgeDiagnostics get currentDiagnostics => _diagnostics;

  Stream<SdkBridgeDiagnostics> watchDiagnostics() async* {
    yield _diagnostics;
    yield* _diagnosticsController.stream;
  }

  void start() {
    if (_started) {
      return;
    }
    _started = true;
    _emitDiagnostics(_diagnostics.copyWith(isActive: true));
    _connectionSub = _connectionStates.listen(
      (state) {
        _connectionState = state;
        if (_canPublishOperationally) {
          unawaited(_flushPendingOperationalItems());
        }
      },
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'BLE operational bridge connection-state error: $error',
        );
      },
    );
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
    _emitDiagnostics(_diagnostics.copyWith(isActive: false));
    await _connectionSub?.cancel();
    await _bleSub?.cancel();
    await _realtimeSub?.cancel();
    await _diagnosticsController.close();
  }

  void clearPendingOperationalItems() {
    _pendingTelemetry = null;
    _pendingSos = null;
    _emitDiagnostics(
      _diagnostics.copyWith(
        pendingTelemetry: null,
        pendingSos: null,
        lastDecision: 'Pending operational items cleared',
      ),
    );
  }

  void resetForSessionChange() {
    clearPendingOperationalItems();
    _flushInProgress = false;
  }

  Future<bool> promoteDeviceOriginatedSos({
    required String signature,
    required String triggerSource,
    required String message,
    required TrackingPosition positionSnapshot,
    String? deviceId,
    String? summary,
  }) async {
    if (!_registerSignature(_recentSosSignatures, signature)) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision: 'SOS skipped: duplicate packet',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge skipped promoted SOS -> reason=duplicate signature=$signature',
      );
      return false;
    }

    if (summary != null && summary.trim().isNotEmpty) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastBleSosEventSummary: summary.trim(),
        ),
      );
    }

    return _publishSosPayload(
      signature: signature,
      triggerSource: triggerSource,
      message: message,
      positionSnapshot: positionSnapshot,
      deviceId: deviceId,
      allowPendingFallback: true,
      relayCount: null,
    );
  }

  Future<void> _handleBleIncomingEvent(BleIncomingEvent event) async {
    switch (event.type) {
      case BleIncomingEventType.deviceRuntimeStatus:
        return;
      case BleIncomingEventType.telPosition:
        await _publishTelemetryIfValid(event);
        return;
      case BleIncomingEventType.telAggregateFragment:
        _emitDiagnostics(
          _diagnostics.copyWith(
            lastDecision: 'TEL aggregate fragment buffered in BLE runtime',
          ),
        );
        BleDebugRegistry.instance.recordEvent(
          'BLE operational bridge observed TEL aggregate fragment -> awaiting_completion deviceId=${event.deviceId}',
        );
        return;
      case BleIncomingEventType.telAggregateComplete:
        await _publishAggregateTelemetryIfMappable(event);
        return;
      case BleIncomingEventType.telRelayRx:
        return;
      case BleIncomingEventType.sosMeshPacket:
        _observeSosIfValid(event);
        return;
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
    await _publishTelemetryPacket(
      event: event,
      packet: packet,
      signature: 'tel:${event.deviceId}:${packet.rawHex}',
      summary:
          'device=${event.deviceId} lat=${packet.position.latitude} lng=${packet.position.longitude} raw=${packet.rawHex}',
    );
  }

  Future<void> _publishAggregateTelemetryIfMappable(
      BleIncomingEvent event) async {
    final aggregatePayload = event.aggregatePayload;
    if (aggregatePayload == null || aggregatePayload.isEmpty) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision: 'TEL aggregate skipped: missing completed payload',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge skipped aggregate telemetry -> reason=missing_payload deviceId=${event.deviceId}',
      );
      return;
    }

    final aggregateHex = EixamBleProtocol.hex(aggregatePayload);
    _emitDiagnostics(
      _diagnostics.copyWith(
        lastBleTelemetryEventSummary:
            'device=${event.deviceId} aggregateLen=${aggregatePayload.length} raw=$aggregateHex',
      ),
    );

    if (aggregatePayload.length != EixamBleProtocol.telPacketLength) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision:
              'TEL aggregate completed but not published: aggregate payload does not fit current telemetry contract',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge skipped aggregate telemetry -> reason=unsupported_contract deviceId=${event.deviceId} aggregateLen=${aggregatePayload.length}',
      );
      return;
    }

    final packet = EixamTelPacket.tryParse(aggregatePayload);
    if (packet == null) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision: 'TEL aggregate skipped: completed payload is invalid',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge skipped aggregate telemetry -> reason=invalid_completed_payload deviceId=${event.deviceId}',
      );
      return;
    }

    await _publishTelemetryPacket(
      event: event,
      packet: packet,
      signature: 'tel-aggregate:${event.deviceId}:${packet.rawHex}',
      summary:
          'device=${event.deviceId} aggregateLen=${aggregatePayload.length} lat=${packet.position.latitude} lng=${packet.position.longitude} raw=${packet.rawHex}',
    );
  }

  Future<void> _publishTelemetryPacket({
    required BleIncomingEvent event,
    required EixamTelPacket packet,
    required String signature,
    required String summary,
  }) async {
    _emitDiagnostics(
      _diagnostics.copyWith(
        lastBleTelemetryEventSummary: summary,
      ),
    );

    final payload = await _buildBackendSafeBleTelemetryPayload(
      event: event,
      packet: packet,
    );
    if (!_hasMinimumTelemetry(payload)) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision: 'Telemetry skipped: minimum fields missing',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge skipped telemetry publish -> reason=minimum_fields_missing deviceId=${event.deviceId}',
      );
      return;
    }
    if (!_registerSignature(_recentTelemetrySignatures, signature)) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision: 'Telemetry skipped: duplicate packet',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge skipped telemetry publish -> reason=duplicate signature=$signature',
      );
      return;
    }

    if (!_canPublishOperationally) {
      _pendingTelemetry = _PendingTelemetryPublish(
        signature: signature,
        payload: payload,
      );
      _emitDiagnostics(
        _diagnostics.copyWith(
          pendingTelemetry: PendingTelemetryDiagnostics(
            signature: signature,
            payload: payload,
          ),
          lastDecision: 'Telemetry buffered: latest sample wins',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge retained pending telemetry -> latest_sample_wins signature=$signature',
      );
      return;
    }

    await _publishTelemetryPayload(
      payload: payload,
      signature: signature,
      allowPendingFallback: true,
    );
  }

  Future<SdkTelemetryPayload> _buildBackendSafeBleTelemetryPayload({
    required BleIncomingEvent event,
    required EixamTelPacket packet,
  }) async {
    // BLE-originated telemetry is intentionally limited to the backend-safe
    // minimum contract for now. The shared SDK payload still exposes richer
    // scalar enrichment fields, but sending them from BLE currently causes
    // backend contract mismatches and blocks ingestion. Unblock ingestion first;
    // revisit enrichment after the SDK and backend payload shapes are aligned.
    return SdkTelemetryPayload(
      timestamp: event.receivedAt.toUtc(),
      latitude: packet.position.latitude,
      longitude: packet.position.longitude,
      altitude: packet.position.altitudeMeters.toDouble(),
      deviceId: await _resolveBackendHardwareId(event),
    );
  }

  void _observeSosIfValid(BleIncomingEvent event) {
    final packet = event.sosPacket;
    if (packet != null) {
      final role = _incomingSosRoleFrom(packet);
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastBleSosEventSummary:
              'device=${event.deviceId} role=${role.label} nodeId=${_formatNodeId(packet.nodeId)} relayCount=${packet.relayCount} raw=${packet.rawHex}',
        ),
      );
    }
    if (packet == null) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision: 'SOS observed only: invalid packet payload',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge observed SOS packet -> reason=invalid_payload deviceId=${event.deviceId}',
      );
      return;
    }

    final signature = 'sos:${event.deviceId}:${packet.rawHex}';
    if (!_registerSignature(_recentSosSignatures, signature)) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision: 'SOS skipped: duplicate packet',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge observed duplicate SOS packet -> signature=$signature',
      );
      return;
    }
    _emitDiagnostics(
      _diagnostics.copyWith(
        lastDecision:
            'SOS observed only: backend lifecycle now waits for device SOS status to become active',
      ),
    );
    BleDebugRegistry.instance.recordEvent(
      'BLE operational bridge observed SOS packet without backend publish -> signature=$signature',
    );
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
      final ackContext = _SosAckRoutingContext.fromStatus(
        deviceSosController.currentStatus,
      );
      switch (confirmation.kind) {
        case _BleBackendConfirmationKind.positionConfirmed:
          await deviceSosController.sendPositionConfirmed();
          _emitDiagnostics(
            _diagnostics.copyWith(
              lastDeviceCommandSent: 'POS_CONFIRMED',
              lastDecision: 'Backend confirmation applied: POS_CONFIRMED sent',
            ),
          );
          break;
        case _BleBackendConfirmationKind.sosAcknowledged:
          await _applySosAcknowledgment(
            confirmation: confirmation,
            context: ackContext,
          );
          break;
        case _BleBackendConfirmationKind.sosRelayAcknowledged:
          await _applySosRelayAcknowledgment(
            confirmation: confirmation,
            context: ackContext,
          );
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

  Future<void> _applySosAcknowledgment({
    required _BleBackendConfirmation confirmation,
    required _SosAckRoutingContext context,
  }) async {
    switch (context.route) {
      case _SosAckRoute.localOrigin:
        await deviceSosController.acknowledgeSos();
        _emitDiagnostics(
          _diagnostics.copyWith(
            lastDeviceCommandSent: 'SOS_ACK',
            lastDecision: 'Backend confirmation applied: SOS_ACK sent',
          ),
        );
        return;
      case _SosAckRoute.relayOrigin:
        final relayNodeId = context.nodeId;
        if (relayNodeId == null) {
          _emitDiagnostics(
            _diagnostics.copyWith(
              lastDecision:
                  'Backend SOS acknowledgment ignored: relay context is missing the origin node id',
            ),
          );
          return;
        }
        await deviceSosController.sendAckRelay(nodeId: relayNodeId);
        _emitDiagnostics(
          _diagnostics.copyWith(
            lastDeviceCommandSent:
                'SOS_ACK_RELAY(${_formatNodeId(relayNodeId)})',
            lastDecision:
                'Backend SOS acknowledgment transformed to SOS_ACK_RELAY using active relay context',
          ),
        );
        return;
      case _SosAckRoute.none:
        _emitDiagnostics(
          _diagnostics.copyWith(
            lastDecision:
                'Backend SOS acknowledgment ignored: ${context.reason}',
          ),
        );
        return;
    }
  }

  Future<void> _applySosRelayAcknowledgment({
    required _BleBackendConfirmation confirmation,
    required _SosAckRoutingContext context,
  }) async {
    if (context.route != _SosAckRoute.relayOrigin) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision:
              'Backend relay acknowledgment ignored: ${context.reason}',
        ),
      );
      return;
    }

    final activeRelayNodeId = context.nodeId;
    final requestedRelayNodeId = confirmation.relayNodeId ?? activeRelayNodeId;
    if (requestedRelayNodeId == null) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision:
              'Backend relay acknowledgment ignored: relay node id is missing',
        ),
      );
      return;
    }

    if (activeRelayNodeId != null &&
        requestedRelayNodeId != activeRelayNodeId) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision:
              'Backend relay acknowledgment ignored: relay node id does not match the active relay SOS context',
        ),
      );
      return;
    }

    await deviceSosController.sendAckRelay(nodeId: requestedRelayNodeId);
    _emitDiagnostics(
      _diagnostics.copyWith(
        lastDeviceCommandSent:
            'SOS_ACK_RELAY(${_formatNodeId(requestedRelayNodeId)})',
        lastDecision: confirmation.relayNodeId == null
            ? 'Backend relay acknowledgment applied using active relay context node id'
            : 'Backend confirmation applied: SOS_ACK_RELAY sent',
      ),
    );
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

  bool get _canPublishOperationally {
    return _sessionProvider() != null &&
        _connectionState == RealtimeConnectionState.connected;
  }

  bool get _hasOperationalSession => _sessionProvider() != null;

  Future<void> _flushPendingOperationalItems() async {
    if (_flushInProgress || !_hasOperationalSession) {
      return;
    }
    _flushInProgress = true;
    try {
      final pendingSos = _pendingSos;
      if (pendingSos != null) {
        final published = await _publishSosPayload(
          signature: pendingSos.signature,
          triggerSource: pendingSos.triggerSource,
          message: pendingSos.message,
          positionSnapshot: pendingSos.positionSnapshot,
          deviceId: pendingSos.deviceId,
          allowPendingFallback: false,
          relayCount: null,
        );
        if (published) {
          _pendingSos = null;
          _emitDiagnostics(_diagnostics.copyWith(pendingSos: null));
        }
      }

      final pendingTelemetry = _pendingTelemetry;
      if (pendingTelemetry != null) {
        final published = await _publishTelemetryPayload(
          payload: pendingTelemetry.payload,
          signature: pendingTelemetry.signature,
          allowPendingFallback: false,
        );
        if (published) {
          _pendingTelemetry = null;
          _emitDiagnostics(_diagnostics.copyWith(pendingTelemetry: null));
        }
      }
    } finally {
      _flushInProgress = false;
    }
  }

  Future<bool> _publishTelemetryPayload({
    required SdkTelemetryPayload payload,
    required String signature,
    required bool allowPendingFallback,
  }) async {
    try {
      await telemetryRepository.publishTelemetry(payload);
      _emitDiagnostics(
        _diagnostics.copyWith(
          pendingTelemetry: null,
          lastDecision: 'Telemetry published',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge published telemetry -> signature=$signature',
      );
      return true;
    } on EixamSdkException catch (error) {
      if (allowPendingFallback && _isOperationalAvailabilityError(error)) {
        _pendingTelemetry = _PendingTelemetryPublish(
          signature: signature,
          payload: payload,
        );
        _emitDiagnostics(
          _diagnostics.copyWith(
            pendingTelemetry: PendingTelemetryDiagnostics(
              signature: signature,
              payload: payload,
            ),
            lastDecision: 'Telemetry buffered after publish failure',
          ),
        );
        BleDebugRegistry.instance.recordEvent(
          'BLE operational bridge retained telemetry after publish failure -> signature=$signature code=${error.code}',
        );
        return false;
      }
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision: 'Telemetry rejected: ${error.code}',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge telemetry publish rejected -> code=${error.code} message=${error.message}',
      );
      return false;
    } catch (error) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision: 'Telemetry publish failed: $error',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge telemetry publish failed -> error=$error',
      );
      return false;
    }
  }

  Future<bool> _publishSosPayload({
    required String signature,
    required String triggerSource,
    required String message,
    required TrackingPosition positionSnapshot,
    required String? deviceId,
    required bool allowPendingFallback,
    required int? relayCount,
  }) async {
    try {
      await sosRepository.triggerSos(
        message: message,
        triggerSource: triggerSource,
        positionSnapshot: positionSnapshot,
        deviceId: deviceId,
      );
      _emitDiagnostics(
        _diagnostics.copyWith(
          pendingSos: null,
          lastDecision: 'SOS published',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge published SOS -> signature=$signature relayCount=${relayCount?.toString() ?? "-"}',
      );
      return true;
    } on SosException catch (error) {
      if (error.code == 'E_SOS_ALREADY_ACTIVE') {
        _emitDiagnostics(
          _diagnostics.copyWith(
            lastDecision: 'SOS skipped: already active',
          ),
        );
        BleDebugRegistry.instance.recordEvent(
          'BLE operational bridge skipped SOS publish -> reason=sos_already_active signature=$signature',
        );
        return false;
      }
      if (allowPendingFallback && _isOperationalAvailabilityError(error)) {
        _pendingSos = _PendingSosPublish(
          signature: signature,
          triggerSource: triggerSource,
          message: message,
          positionSnapshot: positionSnapshot,
          deviceId: deviceId,
        );
        _emitDiagnostics(
          _diagnostics.copyWith(
            pendingSos: PendingSosDiagnostics(
              signature: signature,
              message: message,
              positionSnapshot: positionSnapshot,
            ),
            lastDecision: 'SOS buffered after publish failure',
          ),
        );
        BleDebugRegistry.instance.recordEvent(
          'BLE operational bridge retained SOS after publish failure -> signature=$signature code=${error.code}',
        );
        return false;
      }
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision: 'SOS rejected: ${error.code}',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge SOS publish rejected -> code=${error.code} message=${error.message}',
      );
      return false;
    } catch (error) {
      _emitDiagnostics(
        _diagnostics.copyWith(
          lastDecision: 'SOS publish failed: $error',
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE operational bridge SOS publish failed -> error=$error',
      );
      return false;
    }
  }

  bool _isOperationalAvailabilityError(EixamSdkException error) {
    return error is AuthException ||
        error is NetworkException ||
        error.code == 'E_MQTT_NOT_CONNECTED' ||
        error.code == 'E_SDK_SESSION_REQUIRED' ||
        error.code == 'E_SOS_TRIGGER_FAILED';
  }

  void _emitDiagnostics(SdkBridgeDiagnostics diagnostics) {
    _diagnostics = diagnostics;
    if (!_diagnosticsController.isClosed) {
      _diagnosticsController.add(_diagnostics);
    }
  }

  String _formatNodeId(int nodeId) {
    final normalized = nodeId & 0xFFFF;
    return '0x${normalized.toRadixString(16).padLeft(4, '0')}';
  }

  _IncomingSosRole _incomingSosRoleFrom(EixamSosPacket packet) {
    if (packet.relayCount > 0) {
      return _IncomingSosRole.relayOrigin;
    }
    return _IncomingSosRole.localOrigin;
  }

  Future<String?> _resolveBackendHardwareId(BleIncomingEvent event) async {
    final canonicalHardwareId = event.canonicalHardwareId?.trim();
    if (canonicalHardwareId != null && canonicalHardwareId.isNotEmpty) {
      return canonicalHardwareId;
    }
    final resolver = _backendHardwareIdResolver;
    if (resolver == null) {
      return null;
    }
    try {
      final resolved = await resolver(event.deviceId);
      if (resolved == null || resolved.trim().isEmpty) {
        return null;
      }
      return resolved.trim();
    } catch (_) {
      return null;
    }
  }
}

enum _BleBackendConfirmationKind {
  positionConfirmed,
  sosAcknowledged,
  sosRelayAcknowledged,
}

enum _IncomingSosRole {
  localOrigin('local_origin'),
  relayOrigin('relay_origin');

  const _IncomingSosRole(this.label);

  final String label;
}

enum _SosAckRoute {
  localOrigin,
  relayOrigin,
  none,
}

class _PendingTelemetryPublish {
  const _PendingTelemetryPublish({
    required this.signature,
    required this.payload,
  });

  final String signature;
  final SdkTelemetryPayload payload;
}

class _PendingSosPublish {
  const _PendingSosPublish({
    required this.signature,
    required this.triggerSource,
    required this.message,
    required this.positionSnapshot,
    required this.deviceId,
  });

  final String signature;
  final String triggerSource;
  final String message;
  final TrackingPosition positionSnapshot;
  final String? deviceId;
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

class _SosAckRoutingContext {
  const _SosAckRoutingContext({
    required this.route,
    required this.reason,
    this.nodeId,
  });

  final _SosAckRoute route;
  final String reason;
  final int? nodeId;

  static _SosAckRoutingContext fromStatus(DeviceSosStatus status) {
    if (status.state != DeviceSosState.active) {
      return _SosAckRoutingContext(
        route: _SosAckRoute.none,
        reason: 'no active device SOS is in progress',
        nodeId: status.nodeId,
      );
    }

    if (status.triggerOrigin == DeviceSosTransitionSource.app) {
      return const _SosAckRoutingContext(
        route: _SosAckRoute.localOrigin,
        reason: 'active SOS was triggered locally by the app',
      );
    }

    if (status.triggerOrigin == DeviceSosTransitionSource.device) {
      final relayCount = status.relayCount ?? 0;
      if (relayCount > 0) {
        if (status.nodeId == null) {
          return const _SosAckRoutingContext(
            route: _SosAckRoute.none,
            reason: 'active relay SOS is missing the origin node id',
          );
        }
        return _SosAckRoutingContext(
          route: _SosAckRoute.relayOrigin,
          reason: 'active SOS is a relayed incident',
          nodeId: status.nodeId,
        );
      }
      return const _SosAckRoutingContext(
        route: _SosAckRoute.localOrigin,
        reason: 'active SOS originated on the current device',
      );
    }

    return const _SosAckRoutingContext(
      route: _SosAckRoute.none,
      reason:
          'SOS origin is not known well enough to route backend acknowledgment',
    );
  }
}
