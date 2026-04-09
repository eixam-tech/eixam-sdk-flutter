import 'dart:async';
import 'dart:io';

import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';

import 'sdk_mqtt_contract.dart';
import 'sdk_mqtt_transport.dart';

class Mqtt5SdkTransport implements SdkMqttTransport {
  Mqtt5SdkTransport({
    required this.request,
    required this.enableLogging,
  });

  final SdkMqttConnectRequest request;
  final bool enableLogging;

  final StreamController<SdkMqttIncomingMessage> _messageController =
      StreamController<SdkMqttIncomingMessage>.broadcast();
  final StreamController<SdkMqttDisconnectEvent> _disconnectController =
      StreamController<SdkMqttDisconnectEvent>.broadcast();

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSub;

  @override
  Future<void> connect() async {
    await disconnect();

    final brokerUri = request.brokerUri;
    final server = _serverStringFor(brokerUri);
    final client = MqttServerClient(server, request.clientIdentifier);
    client.logging(on: enableLogging, logPayloads: enableLogging);
    client.keepAlivePeriod = 30;
    client.port =
        brokerUri.hasPort ? brokerUri.port : _defaultPortFor(brokerUri);
    client.useWebSocket = brokerUri.scheme == 'ws' || brokerUri.scheme == 'wss';
    client.secure = brokerUri.scheme == 'ssl' || brokerUri.scheme == 'tls';
    client.onDisconnected = () {
      final solicited = client.connectionStatus?.disconnectionOrigin ==
          MqttDisconnectionOrigin.solicited;
      _disconnectController.add(
        SdkMqttDisconnectEvent(solicited: solicited),
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
      throw StateError('MQTT socket connect failed: ${error.message}');
    } on Exception catch (error) {
      throw StateError('MQTT connect failed: $error');
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      final status = client.connectionStatus;
      throw StateError(
        'MQTT connect rejected: ${status?.state.name ?? 'unknown'} ${status?.reasonCode ?? ''}',
      );
    }

    _client = client;
    _updatesSub = client.updates.listen((messages) {
      for (final message in messages) {
        final publishMessage = message.payload;
        if (publishMessage is! MqttPublishMessage) {
          continue;
        }
        final payload = MqttUtilities.bytesToStringAsString(
            publishMessage.payload.message!);
        _messageController.add(
          SdkMqttIncomingMessage(
            topic: message.topic ?? '',
            payload: payload,
          ),
        );
      }
    });
  }

  @override
  Future<void> disconnect() async {
    await _updatesSub?.cancel();
    _updatesSub = null;
    final client = _client;
    _client = null;
    client?.disconnect();
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
    await disconnect();
    await _messageController.close();
    await _disconnectController.close();
  }

  MqttServerClient _requireClient() {
    final client = _client;
    if (client == null ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      throw StateError('MQTT client is not connected.');
    }
    return client;
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
