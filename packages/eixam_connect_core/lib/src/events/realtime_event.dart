class RealtimeEvent {
  const RealtimeEvent({
    required this.type,
    required this.timestamp,
    this.payload,
  });

  final String type;
  final DateTime timestamp;
  final Map<String, dynamic>? payload;
}
