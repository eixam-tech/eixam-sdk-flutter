import '../../bootstrap/validation_backend_config.dart';

class ValidationSessionDraft {
  const ValidationSessionDraft({
    required this.backendPreset,
    required this.appId,
    required this.externalUserId,
    this.userHash = '',
  });

  final ValidationBackendPreset backendPreset;
  final String appId;
  final String externalUserId;
  final String userHash;
}

class ValidationSessionPreset {
  const ValidationSessionPreset({
    required this.id,
    required this.label,
    required this.backendPreset,
    required this.appId,
    required this.externalUserIdPrefix,
  });

  final String id;
  final String label;
  final ValidationBackendPreset backendPreset;
  final String appId;
  final String externalUserIdPrefix;

  ValidationSessionDraft createDraft({DateTime? now}) {
    final timestamp = (now ?? DateTime.now().toUtc());
    return ValidationSessionDraft(
      backendPreset: backendPreset,
      appId: appId,
      externalUserId: _buildExternalUserId(timestamp),
    );
  }

  String _buildExternalUserId(DateTime timestamp) {
    final year = timestamp.year.toString().padLeft(4, '0');
    final month = timestamp.month.toString().padLeft(2, '0');
    final day = timestamp.day.toString().padLeft(2, '0');
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final second = timestamp.second.toString().padLeft(2, '0');
    final millis = (timestamp.millisecond + (timestamp.microsecond ~/ 1000))
        .toString()
        .padLeft(3, '0');
    return '$externalUserIdPrefix-$year$month$day-$hour$minute$second-$millis';
  }

  static const ValidationSessionPreset eixamStaging = ValidationSessionPreset(
    id: 'eixam-staging',
    label: 'EIXAM staging',
    backendPreset: ValidationBackendPreset.staging,
    appId: 'app_u8eetxk3kqgf',
    externalUserIdPrefix: 'eixam-staging',
  );

  static const List<ValidationSessionPreset> testOnlyPresets =
      <ValidationSessionPreset>[eixamStaging];
}
