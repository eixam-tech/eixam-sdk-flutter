import '../enums/sos_state.dart';
import 'public_pre_sos_status.dart';
import 'sos_incident.dart';

enum OsSosWidgetPlatform { android, ios }

enum OsSosWidgetConfirmationMode { countdown, hold, appOpened }

enum OsSosWidgetActivationOutcome {
  countdownStarted,
  countdownAlreadyRunning,
  activeSosAlreadyRunning,
  activated,
  confirmationRequired,
  duplicateIgnored,
}

class OsSosWidgetActivation {
  const OsSosWidgetActivation({
    required this.platform,
    required this.actionId,
    required this.nonce,
    required this.timestamp,
    required this.confirmationMode,
  });

  static const String source = 'os_widget';

  final OsSosWidgetPlatform platform;
  final String actionId;
  final String nonce;
  final DateTime timestamp;
  final OsSosWidgetConfirmationMode confirmationMode;

  String get confirmationModeWireName {
    return switch (confirmationMode) {
      OsSosWidgetConfirmationMode.countdown => 'countdown',
      OsSosWidgetConfirmationMode.hold => 'hold',
      OsSosWidgetConfirmationMode.appOpened => 'app_opened',
    };
  }

  String get idempotencyKey {
    final normalizedActionId = actionId.trim();
    if (normalizedActionId.isNotEmpty) {
      return normalizedActionId;
    }
    return nonce.trim();
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'source': source,
      'platform': platform.name,
      'actionId': actionId,
      'nonce': nonce,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'confirmationMode': confirmationModeWireName,
    };
  }

  static OsSosWidgetActivation? fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return null;
    }
    final platformName = json['platform'] as String?;
    final confirmationModeName = json['confirmationMode'] as String?;
    final timestampRaw = json['timestamp'] as String?;
    final platform = OsSosWidgetPlatform.values.firstWhere(
      (value) => value.name == platformName,
      orElse: () => OsSosWidgetPlatform.android,
    );
    final confirmationMode = _confirmationModeFromWireName(
      confirmationModeName,
    );
    final timestamp = timestampRaw == null
        ? null
        : DateTime.tryParse(timestampRaw)?.toUtc();
    return OsSosWidgetActivation(
      platform: platform,
      actionId: json['actionId'] as String? ?? '',
      nonce: json['nonce'] as String? ?? '',
      timestamp: timestamp ?? DateTime.now().toUtc(),
      confirmationMode: confirmationMode,
    );
  }

  static OsSosWidgetConfirmationMode _confirmationModeFromWireName(
    String? value,
  ) {
    switch (value) {
      case 'countdown':
        return OsSosWidgetConfirmationMode.countdown;
      case 'hold':
        return OsSosWidgetConfirmationMode.hold;
      case 'app_opened':
      case 'appOpened':
        return OsSosWidgetConfirmationMode.appOpened;
      default:
        return OsSosWidgetConfirmationMode.appOpened;
    }
  }
}

class OsSosWidgetActivationResult {
  const OsSosWidgetActivationResult({
    required this.outcome,
    required this.source,
    required this.platform,
    required this.actionId,
    required this.nonce,
    required this.timestamp,
    required this.confirmationMode,
    this.sosState,
    this.incident,
    this.preSosStatus,
  });

  final OsSosWidgetActivationOutcome outcome;
  final String source;
  final OsSosWidgetPlatform platform;
  final String actionId;
  final String nonce;
  final DateTime timestamp;
  final OsSosWidgetConfirmationMode confirmationMode;
  final SosState? sosState;
  final SosIncident? incident;
  final PublicPreSosStatus? preSosStatus;

  bool get shouldOpenApp =>
      outcome == OsSosWidgetActivationOutcome.activeSosAlreadyRunning ||
      outcome == OsSosWidgetActivationOutcome.confirmationRequired;

  bool get shouldOpenActiveSos =>
      outcome == OsSosWidgetActivationOutcome.activeSosAlreadyRunning;

  bool get shouldOpenConfirmation =>
      outcome == OsSosWidgetActivationOutcome.confirmationRequired;

  factory OsSosWidgetActivationResult.fromActivation({
    required OsSosWidgetActivation activation,
    required OsSosWidgetActivationOutcome outcome,
    SosState? sosState,
    SosIncident? incident,
    PublicPreSosStatus? preSosStatus,
  }) {
    return OsSosWidgetActivationResult(
      outcome: outcome,
      source: OsSosWidgetActivation.source,
      platform: activation.platform,
      actionId: activation.actionId,
      nonce: activation.nonce,
      timestamp: activation.timestamp,
      confirmationMode: activation.confirmationMode,
      sosState: sosState,
      incident: incident,
      preSosStatus: preSosStatus,
    );
  }
}
