enum SosActuatorType {
  emergencyContacts,
  slack,
  webhook,
  unknown,
}

enum SosActuatorStatus {
  scheduled,
  sent,
  delivered,
  failed,
  skipped,
  unknown,
}

enum SosActuatorOutcome {
  pending,
  success,
  failure,
  skipped,
  unknown,
}

enum SosActuatorChannelKind {
  sms,
  email,
  phone,
  voice,
  push,
  whatsapp,
  slack,
  webhook,
  unknown,
}

class SosActuatorSnapshot {
  factory SosActuatorSnapshot.fromJson(Map<String, dynamic> json) {
    return SosActuatorSnapshot(
      snapshotVersion: _intFromJson(json['snapshotVersion']) ??
          _intFromJson(json['snapshot_version']) ??
          0,
      items: _listFromJson(json['items'])
          .map(SosActuatorItem.fromJson)
          .toList(growable: false),
    );
  }
  const SosActuatorSnapshot({
    required this.snapshotVersion,
    this.items = const [],
  });

  final int snapshotVersion;
  final List<SosActuatorItem> items;

  int get pendingCount => _countByOutcome(SosActuatorOutcome.pending);
  int get successCount => _countByOutcome(SosActuatorOutcome.success);
  int get failureCount => _countByOutcome(SosActuatorOutcome.failure);
  int get skippedCount => _countByOutcome(SosActuatorOutcome.skipped);

  bool get hasPending => pendingCount > 0;
  bool get hasSuccesses => successCount > 0;
  bool get hasFailures => failureCount > 0;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'snapshotVersion': snapshotVersion,
      'items': items.map((item) => item.toJson()).toList(growable: false),
    };
  }

  int _countByOutcome(SosActuatorOutcome outcome) {
    return items.where((item) => item.outcome == outcome).length;
  }
}

class SosActuatorItem {
  factory SosActuatorItem.fromJson(Map<String, dynamic> json) {
    final rawType = _stringFromJson(json['type']) ?? '';
    final rawStatus = _stringFromJson(json['status']) ?? '';
    final status = _statusFromRaw(rawStatus);
    final rawOutcome = _stringFromJson(json['outcome']);
    return SosActuatorItem(
      id: _stringFromJson(json['id']) ?? rawType,
      type: _typeFromRaw(rawType),
      rawType: rawType,
      status: status,
      rawStatus: rawStatus,
      outcome: rawOutcome == null
          ? _outcomeFromStatus(status)
          : _outcomeFromRaw(rawOutcome),
      rawOutcome: rawOutcome ?? _rawOutcomeFromStatus(status),
      updatedAt: _dateTimeFromJson(json['updatedAt'] ?? json['updated_at']),
      contacts: _listFromJson(json['contacts'])
          .map(SosActuatorContact.fromJson)
          .toList(growable: false),
      deliveries: _listFromJson(json['deliveries'])
          .map(SosActuatorDelivery.fromJson)
          .toList(growable: false),
    );
  }
  const SosActuatorItem({
    required this.id,
    required this.type,
    required this.rawType,
    required this.status,
    required this.rawStatus,
    required this.outcome,
    required this.rawOutcome,
    this.updatedAt,
    this.contacts = const [],
    this.deliveries = const [],
  });

  final String id;
  final SosActuatorType type;
  final String rawType;
  final SosActuatorStatus status;
  final String rawStatus;
  final SosActuatorOutcome outcome;
  final String rawOutcome;
  final DateTime? updatedAt;
  final List<SosActuatorContact> contacts;
  final List<SosActuatorDelivery> deliveries;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'type': rawType,
      'status': rawStatus,
      'outcome': rawOutcome,
      'updatedAt': updatedAt?.toIso8601String(),
      'contacts':
          contacts.map((contact) => contact.toJson()).toList(growable: false),
      'deliveries': deliveries
          .map((delivery) => delivery.toJson())
          .toList(growable: false),
    };
  }
}

class SosActuatorContact {
  factory SosActuatorContact.fromJson(Map<String, dynamic> json) {
    final rawStatus = _stringFromJson(json['status']);
    final status = _statusFromRaw(rawStatus);
    final rawOutcome = _stringFromJson(json['outcome']);
    final rawChannel = _stringFromJson(json['channel']);
    return SosActuatorContact(
      id: _stringFromJson(
        json['contactId'] ?? json['contact_id'] ?? json['id'],
      ),
      name: _stringFromJson(json['name']),
      phone: _stringFromJson(json['phone']),
      email: _stringFromJson(json['email']),
      channel: _channelFromRaw(rawChannel),
      rawChannel: rawChannel,
      status: status,
      rawStatus: rawStatus,
      outcome: rawOutcome == null
          ? _outcomeFromStatus(status)
          : _outcomeFromRaw(rawOutcome),
      rawOutcome: rawOutcome ?? _rawOutcomeFromStatus(status),
      updatedAt: _dateTimeFromJson(json['updatedAt'] ?? json['updated_at']),
      acknowledgedAt:
          _dateTimeFromJson(json['acknowledgedAt'] ?? json['acknowledged_at']),
      channels: _listFromJson(json['channels'])
          .map(SosActuatorChannel.fromJson)
          .toList(growable: false),
    );
  }
  const SosActuatorContact({
    this.id,
    this.name,
    this.phone,
    this.email,
    required this.channel,
    required this.rawChannel,
    required this.status,
    required this.rawStatus,
    required this.outcome,
    required this.rawOutcome,
    this.updatedAt,
    this.acknowledgedAt,
    this.channels = const [],
  });

  final String? id;
  final String? name;
  final String? phone;
  final String? email;
  final SosActuatorChannelKind channel;
  final String? rawChannel;
  final SosActuatorStatus status;
  final String? rawStatus;
  final SosActuatorOutcome outcome;
  final String? rawOutcome;
  final DateTime? updatedAt;
  final DateTime? acknowledgedAt;
  final List<SosActuatorChannel> channels;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'phone': phone,
      'email': email,
      'channel': rawChannel,
      'status': rawStatus,
      'outcome': rawOutcome,
      'updatedAt': updatedAt?.toIso8601String(),
      'acknowledgedAt': acknowledgedAt?.toIso8601String(),
      'channels':
          channels.map((channel) => channel.toJson()).toList(growable: false),
    };
  }
}

class SosActuatorChannel {
  factory SosActuatorChannel.fromJson(Map<String, dynamic> json) {
    final rawStatus = _stringFromJson(json['status']);
    final status = _statusFromRaw(rawStatus);
    final rawOutcome = _stringFromJson(json['outcome']);
    final rawKind =
        _stringFromJson(json['channel']) ?? _stringFromJson(json['type']);
    return SosActuatorChannel(
      id: _stringFromJson(json['id']),
      kind: _channelFromRaw(rawKind),
      rawKind: rawKind,
      address: _stringFromJson(json['address']),
      target: _stringFromJson(json['target']),
      status: status,
      rawStatus: rawStatus,
      outcome: rawOutcome == null
          ? _outcomeFromStatus(status)
          : _outcomeFromRaw(rawOutcome),
      rawOutcome: rawOutcome ?? _rawOutcomeFromStatus(status),
      updatedAt: _dateTimeFromJson(json['updatedAt'] ?? json['updated_at']),
      acknowledgedAt:
          _dateTimeFromJson(json['acknowledgedAt'] ?? json['acknowledged_at']),
    );
  }
  const SosActuatorChannel({
    this.id,
    required this.kind,
    required this.rawKind,
    this.address,
    this.target,
    required this.status,
    required this.rawStatus,
    required this.outcome,
    required this.rawOutcome,
    this.updatedAt,
    this.acknowledgedAt,
  });

  final String? id;
  final SosActuatorChannelKind kind;
  final String? rawKind;
  final String? address;
  final String? target;
  final SosActuatorStatus status;
  final String? rawStatus;
  final SosActuatorOutcome outcome;
  final String? rawOutcome;
  final DateTime? updatedAt;
  final DateTime? acknowledgedAt;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'channel': rawKind,
      'address': address,
      'target': target,
      'status': rawStatus,
      'outcome': rawOutcome,
      'updatedAt': updatedAt?.toIso8601String(),
      'acknowledgedAt': acknowledgedAt?.toIso8601String(),
    };
  }
}

class SosActuatorDelivery {
  factory SosActuatorDelivery.fromJson(Map<String, dynamic> json) {
    final rawStatus = _stringFromJson(json['status']);
    final status = _statusFromRaw(rawStatus);
    final rawOutcome = _stringFromJson(json['outcome']);
    final rawChannel =
        _stringFromJson(json['channel']) ?? _stringFromJson(json['type']);
    return SosActuatorDelivery(
      id: _stringFromJson(json['id']),
      channel: _channelFromRaw(rawChannel),
      rawChannel: rawChannel,
      status: status,
      rawStatus: rawStatus,
      outcome: rawOutcome == null
          ? _outcomeFromStatus(status)
          : _outcomeFromRaw(rawOutcome),
      rawOutcome: rawOutcome ?? _rawOutcomeFromStatus(status),
      updatedAt: _dateTimeFromJson(json['updatedAt'] ?? json['updated_at']),
      deliveredAt:
          _dateTimeFromJson(json['deliveredAt'] ?? json['delivered_at']),
      failedAt: _dateTimeFromJson(json['failedAt'] ?? json['failed_at']),
      target: _stringFromJson(json['target']),
      error: _stringFromJson(json['error']),
    );
  }
  const SosActuatorDelivery({
    this.id,
    required this.channel,
    required this.rawChannel,
    required this.status,
    required this.rawStatus,
    required this.outcome,
    required this.rawOutcome,
    this.updatedAt,
    this.deliveredAt,
    this.failedAt,
    this.target,
    this.error,
  });

  final String? id;
  final SosActuatorChannelKind channel;
  final String? rawChannel;
  final SosActuatorStatus status;
  final String? rawStatus;
  final SosActuatorOutcome outcome;
  final String? rawOutcome;
  final DateTime? updatedAt;
  final DateTime? deliveredAt;
  final DateTime? failedAt;
  final String? target;
  final String? error;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'channel': rawChannel,
      'status': rawStatus,
      'outcome': rawOutcome,
      'updatedAt': updatedAt?.toIso8601String(),
      'deliveredAt': deliveredAt?.toIso8601String(),
      'failedAt': failedAt?.toIso8601String(),
      'target': target,
      'error': error,
    };
  }
}

SosActuatorType _typeFromRaw(String raw) {
  return switch (_normalize(raw)) {
    'emergency_contacts' ||
    'emergencycontacts' =>
      SosActuatorType.emergencyContacts,
    'slack' => SosActuatorType.slack,
    'webhook' => SosActuatorType.webhook,
    _ => SosActuatorType.unknown,
  };
}

SosActuatorStatus _statusFromRaw(String? raw) {
  return switch (_normalize(raw)) {
    'scheduled' || 'queued' => SosActuatorStatus.scheduled,
    'sent' || 'ringing' || 'in_progress' => SosActuatorStatus.sent,
    'delivered' || 'completed' || 'acknowledged' => SosActuatorStatus.delivered,
    'failed' ||
    'no_answer' ||
    'busy' ||
    'canceled' ||
    'cancelled' ||
    'undelivered' =>
      SosActuatorStatus.failed,
    'skipped' => SosActuatorStatus.skipped,
    _ => SosActuatorStatus.unknown,
  };
}

SosActuatorOutcome _outcomeFromRaw(String raw) {
  return switch (_normalize(raw)) {
    'pending' => SosActuatorOutcome.pending,
    'success' => SosActuatorOutcome.success,
    'failure' => SosActuatorOutcome.failure,
    'skipped' => SosActuatorOutcome.skipped,
    _ => SosActuatorOutcome.unknown,
  };
}

SosActuatorOutcome _outcomeFromStatus(SosActuatorStatus status) {
  return switch (status) {
    SosActuatorStatus.sent ||
    SosActuatorStatus.delivered =>
      SosActuatorOutcome.success,
    SosActuatorStatus.failed => SosActuatorOutcome.failure,
    SosActuatorStatus.scheduled => SosActuatorOutcome.pending,
    SosActuatorStatus.skipped => SosActuatorOutcome.skipped,
    SosActuatorStatus.unknown => SosActuatorOutcome.unknown,
  };
}

String _rawOutcomeFromStatus(SosActuatorStatus status) {
  return switch (_outcomeFromStatus(status)) {
    SosActuatorOutcome.success => 'success',
    SosActuatorOutcome.failure => 'failure',
    SosActuatorOutcome.pending => 'pending',
    SosActuatorOutcome.skipped => 'skipped',
    SosActuatorOutcome.unknown => '',
  };
}

SosActuatorChannelKind _channelFromRaw(String? raw) {
  return switch (_normalize(raw)) {
    'sms' => SosActuatorChannelKind.sms,
    'email' => SosActuatorChannelKind.email,
    'phone' => SosActuatorChannelKind.phone,
    'voice' || 'call' => SosActuatorChannelKind.voice,
    'push' => SosActuatorChannelKind.push,
    'whatsapp' => SosActuatorChannelKind.whatsapp,
    'slack' => SosActuatorChannelKind.slack,
    'webhook' => SosActuatorChannelKind.webhook,
    _ => SosActuatorChannelKind.unknown,
  };
}

String _normalize(String? raw) {
  return raw?.trim().toLowerCase().replaceAll('-', '_') ?? '';
}

String? _stringFromJson(Object? value) {
  final normalized = value?.toString().trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  return normalized;
}

int? _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

DateTime? _dateTimeFromJson(Object? value) {
  final raw = _stringFromJson(value);
  if (raw == null) {
    return null;
  }
  return DateTime.tryParse(raw);
}

List<Map<String, dynamic>> _listFromJson(Object? value) {
  if (value is! List) {
    return const <Map<String, dynamic>>[];
  }
  return value.whereType<Map>().map((item) {
    return Map<String, dynamic>.from(item);
  }).toList(growable: false);
}
