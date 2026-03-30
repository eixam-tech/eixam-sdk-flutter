import 'dart:async';

class SdkMqttIncomingMessage {
  const SdkMqttIncomingMessage({
    required this.topic,
    required this.payload,
  });

  final String topic;
  final String payload;
}

class SdkMqttDisconnectEvent {
  const SdkMqttDisconnectEvent({
    required this.solicited,
    this.error,
  });

  final bool solicited;
  final Object? error;
}

abstract class SdkMqttTransport {
  Future<void> connect();
  Future<void> disconnect();
  Future<void> dispose();
  Future<void> subscribe(String topic);
  Future<void> publish({
    required String topic,
    required String payload,
  });

  Stream<SdkMqttIncomingMessage> watchMessages();
  Stream<SdkMqttDisconnectEvent> watchDisconnects();
}
