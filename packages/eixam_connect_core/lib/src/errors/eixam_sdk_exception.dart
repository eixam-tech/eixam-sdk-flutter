import '../profile/sdk_profile_validation.dart';

sealed class EixamSdkException implements Exception {
  const EixamSdkException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'EixamSdkException(code: $code, message: $message)';
}

class AuthException extends EixamSdkException {
  const AuthException(super.code, super.message);
}

class NetworkException extends EixamSdkException {
  const NetworkException(super.code, super.message);
}

class SosException extends EixamSdkException {
  const SosException(super.code, super.message);
}

class SosHttpException extends SosException {
  const SosHttpException(
    super.code,
    super.message, {
    required this.statusCode,
  });

  final int statusCode;
}

class TrackingException extends EixamSdkException {
  const TrackingException(super.code, super.message);
}

class DeviceException extends EixamSdkException {
  const DeviceException(super.code, super.message);

  const DeviceException.invalidPairingCode()
      : this('E_DEVICE_INVALID_PAIRING_CODE', 'The pairing code is not valid.');

  const DeviceException.invalidActivationCode()
      : this('E_DEVICE_INVALID_ACTIVATION_CODE',
            'The activation code is not valid.');

  const DeviceException.notPaired()
      : this('E_DEVICE_NOT_PAIRED',
            'The device must be paired before this action.');

  const DeviceException.notActivated()
      : this('E_DEVICE_NOT_ACTIVATED',
            'The device must be activated before this action.');
}

class ContactsException extends EixamSdkException {
  const ContactsException(super.code, super.message);
}

/// HTTP failures for `/v1/sdk/contacts` routes with optional parsed API error.
class ContactsHttpException extends ContactsException {
  const ContactsHttpException(
    super.code,
    super.message, {
    required this.statusCode,
    this.rawBody,
    this.apiErrorCode,
    this.apiErrorMessage,
  });

  final int statusCode;
  final String? rawBody;
  final String? apiErrorCode;
  final String? apiErrorMessage;

  @override
  String toString() {
    final apiPart = apiErrorCode == null ? '' : ', apiErrorCode: $apiErrorCode';
    return 'ContactsHttpException('
        'code: $code, '
        'statusCode: $statusCode'
        '$apiPart, '
        'message: $message'
        ')';
  }
}

class DeathManException extends EixamSdkException {
  const DeathManException(super.code, super.message);
}

/// HTTP failures for `GET`/`PUT /v1/sdk/me` with optional parsed API error envelope.
class ProfileHttpException extends EixamSdkException {
  const ProfileHttpException(
    super.code,
    super.message, {
    required this.statusCode,
    this.rawBody,
    this.apiErrorCode,
    this.apiErrorMessage,
    this.fieldHints = const [],
  });

  final int statusCode;
  final String? rawBody;
  final String? apiErrorCode;
  final String? apiErrorMessage;
  final List<SdkProfileApiFieldHint> fieldHints;
}

class RescueException extends EixamSdkException {
  const RescueException(super.code, super.message);

  const RescueException.notImplemented()
      : this(
          'E_RESCUE_NOT_IMPLEMENTED',
          'Guided Rescue Phase 1 is not implemented in the current SDK runtime.',
        );

  const RescueException.missingSession()
      : this(
          'E_RESCUE_SESSION_REQUIRED',
          'A guided rescue session must be configured before issuing rescue commands.',
        );
}
