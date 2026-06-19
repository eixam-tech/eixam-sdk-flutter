import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';

import 'sdk_mqtt_contract.dart';
import 'sdk_mqtt_transport.dart';
import 'transport_security_validator.dart';

class Mqtt5SdkTransport implements SdkMqttTransport {
  Mqtt5SdkTransport({
    required this.request,
    required this.enableLogging,
  }) {
    SdkTransportSecurityValidator.validateRealtimeEndpoint(
      EixamSdkConfig(
        apiBaseUrl: 'https://transport-validation.local',
        websocketUrl: request.brokerUri.toString(),
        allowInsecureLocalEndpoints: request.allowInsecureLocalEndpoint,
      ),
      endpoint: request.brokerUri.toString(),
    );
  }

  final SdkMqttConnectRequest request;
  final bool enableLogging;

  final StreamController<SdkMqttIncomingMessage> _messageController =
      StreamController<SdkMqttIncomingMessage>.broadcast();
  final StreamController<SdkMqttDisconnectEvent> _disconnectController =
      StreamController<SdkMqttDisconnectEvent>.broadcast();

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSub;
  bool _disposed = false;

  @override
  Future<void> connect() async {
    if (_disposed) {
      _logTransport('connect_skipped reason=disposed');
      return;
    }
    await disconnect();

    final brokerUri = request.brokerUri;
    final server = _serverStringFor(brokerUri);
    final client = MqttServerClient(server, request.clientIdentifier);
    _logTransport(
      'connect_start uri=${_redactedUri(brokerUri)} server=$server '
      'port=${brokerUri.hasPort ? brokerUri.port : _defaultPortFor(brokerUri)} '
      'websocket=${brokerUri.scheme == 'ws' || brokerUri.scheme == 'wss'} '
      'secure=${brokerUri.scheme == 'ssl' || brokerUri.scheme == 'tls'}',
    );
    client.logging(on: kDebugMode && enableLogging, logPayloads: false);
    client.keepAlivePeriod = 30;
    client.port =
        brokerUri.hasPort ? brokerUri.port : _defaultPortFor(brokerUri);
    client.useWebSocket = brokerUri.scheme == 'ws' || brokerUri.scheme == 'wss';
    client.secure = brokerUri.scheme == 'ssl' || brokerUri.scheme == 'tls';
    client.onDisconnected = () {
      final solicited = client.connectionStatus?.disconnectionOrigin ==
          MqttDisconnectionOrigin.solicited;
      _logTransport(
        'MQTT_TRANSPORT_DISCONNECT_HANDLED solicited=$solicited',
      );
      _safeAddDisconnect(
        SdkMqttDisconnectEvent(solicited: solicited),
        source: 'on_disconnected',
      );
    };
    client.onBadCertificate = (_) => false;
    var connectMessage =
        MqttConnectMessage().withClientIdentifier(request.clientIdentifier);
    if (request.cleanSession) {
      connectMessage = connectMessage.startClean();
    }
    client.connectionMessage = connectMessage
        .keepAliveFor(30)
        .authenticateAs(request.username, request.password);

    try {
      await client.connect();
    } on SocketException catch (error) {
      _logTransport(
        'MQTT_TRANSPORT_SOCKET_ERROR_HANDLED '
        'phase=connect error=${error.message}',
      );
      throw StateError('MQTT socket connect failed: ${error.message}');
    } on TimeoutException catch (error) {
      _logTransport(
        'MQTT_TRANSPORT_SOCKET_ERROR_HANDLED '
        'phase=connect_timeout error=${error.message ?? error.toString()}',
      );
      throw StateError('MQTT connect timed out: $error');
    } on Exception catch (error) {
      _logTransport(
        'MQTT_TRANSPORT_DISCONNECT_HANDLED phase=connect_failure error=$error',
      );
      throw StateError('MQTT connect failed: $error');
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      final status = client.connectionStatus;
      _logTransport(
        'connect_rejected state=${status?.state.name ?? 'unknown'} '
        'reason=${status?.reasonCode ?? ''}',
      );
      throw StateError(
        'MQTT connect rejected: ${status?.state.name ?? 'unknown'} ${status?.reasonCode ?? ''}',
      );
    }
    _logTransport('connect_success uri=${_redactedUri(brokerUri)}');

    _client = client;
    _updatesSub = client.updates.listen((messages) {
      try {
        for (final message in messages) {
          final publishMessage = message.payload;
          if (publishMessage is! MqttPublishMessage) {
            continue;
          }
          final payload = MqttUtilities.bytesToStringAsString(
              publishMessage.payload.message!);
          _safeAddMessage(
            SdkMqttIncomingMessage(
              topic: message.topic ?? '',
              payload: payload,
            ),
          );
        }
      } catch (error, stackTrace) {
        _logTransport(
          'MQTT_TRANSPORT_DISCONNECT_HANDLED '
          'phase=message_handler error=$error stack=${_stackSummary(stackTrace)}',
        );
      }
    }, onError: (Object error, StackTrace stackTrace) {
      final marker = error is SocketException
          ? 'MQTT_TRANSPORT_SOCKET_ERROR_HANDLED'
          : 'MQTT_TRANSPORT_DISCONNECT_HANDLED';
      _logTransport(
        '$marker phase=updates_stream error=$error '
        'stack=${_stackSummary(stackTrace)}',
      );
      _safeAddDisconnect(
        const SdkMqttDisconnectEvent(solicited: false),
        source: 'updates_error',
      );
    });
  }

  @override
  Future<void> disconnect() async {
    try {
      await _updatesSub?.cancel();
    } catch (error) {
      _logTransport(
        'MQTT_TRANSPORT_DISCONNECT_HANDLED phase=cancel_updates error=$error',
      );
    }
    _updatesSub = null;
    final client = _client;
    _client = null;
    try {
      client?.disconnect();
      if (client != null) {
        _logTransport(
          'MQTT_TRANSPORT_DISCONNECT_HANDLED solicited=true phase=disconnect',
        );
      }
    } catch (error) {
      _logTransport(
        'MQTT_TRANSPORT_DISCONNECT_HANDLED phase=disconnect error=$error',
      );
    }
  }

  @override
  Future<void> subscribe(String topic) async {
    final client = _requireClient();
    client.subscribe(topic, MqttQos.atLeastOnce);
  }

  @override
  Future<void> publish({
    required String topic,
    required String payload,
    SdkMqttQos qos = SdkMqttQos.atLeastOnce,
    bool retain = false,
  }) async {
    final client = _requireClient();
    final builder = MqttPayloadBuilder()..addString(payload);
    client.publishMessage(
      topic,
      _toMqttQos(qos),
      builder.payload!,
      retain: retain,
    );
  }

  @override
  Stream<SdkMqttIncomingMessage> watchMessages() => _messageController.stream;

  @override
  Stream<SdkMqttDisconnectEvent> watchDisconnects() =>
      _disconnectController.stream;

  @override
  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    if (!_messageController.isClosed) {
      await _messageController.close();
    }
    if (!_disconnectController.isClosed) {
      await _disconnectController.close();
    }
  }

  MqttServerClient _requireClient() {
    final client = _client;
    if (client == null ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      throw StateError('MQTT client is not connected.');
    }
    return client;
  }

  void _logTransport(String message) {
    if (!kDebugMode || !enableLogging) {
      return;
    }
    debugPrint(message);
  }

  void _safeAddMessage(SdkMqttIncomingMessage message) {
    if (_messageController.isClosed) {
      _logTransport(
        'MQTT_TRANSPORT_EVENT_DROPPED_CLOSED_CONTROLLER type=message',
      );
      return;
    }
    try {
      _messageController.add(message);
    } catch (error) {
      _logTransport(
        'MQTT_TRANSPORT_EVENT_DROPPED_CLOSED_CONTROLLER '
        'type=message error=$error',
      );
    }
  }

  void _safeAddDisconnect(
    SdkMqttDisconnectEvent event, {
    required String source,
  }) {
    if (_disconnectController.isClosed) {
      _logTransport(
        'MQTT_TRANSPORT_EVENT_DROPPED_CLOSED_CONTROLLER '
        'type=disconnect source=$source',
      );
      return;
    }
    try {
      _disconnectController.add(event);
    } catch (error) {
      _logTransport(
        'MQTT_TRANSPORT_EVENT_DROPPED_CLOSED_CONTROLLER '
        'type=disconnect source=$source error=$error',
      );
    }
  }

  String _stackSummary(StackTrace stackTrace) {
    final text = stackTrace.toString();
    final newline = text.indexOf('\n');
    return newline == -1 ? text : text.substring(0, newline);
  }

  String _redactedUri(Uri uri) {
    return uri.replace(userInfo: '').toString();
  }

  String _serverStringFor(Uri brokerUri) {
    if (brokerUri.scheme == 'ws' || brokerUri.scheme == 'wss') {
      final path = brokerUri.path.isEmpty ? '' : brokerUri.path;
      return '${brokerUri.scheme}://${brokerUri.host}$path';
    }
    return brokerUri.host;
  }

  int _defaultPortFor(Uri brokerUri) {
    return switch (brokerUri.scheme) {
      'wss' => 443,
      'ws' => 80,
      'ssl' || 'tls' => 8883,
      _ => 1883,
    };
  }

  MqttQos _toMqttQos(SdkMqttQos qos) {
    return switch (qos) {
      SdkMqttQos.atMostOnce => MqttQos.atMostOnce,
      SdkMqttQos.atLeastOnce => MqttQos.atLeastOnce,
      SdkMqttQos.exactlyOnce => MqttQos.exactlyOnce,
    };
  }
}
