sealed class EixamSdkException implements Exception {
  final String code;
  final String message;

  const EixamSdkException(this.code, this.message);

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

class TrackingException extends EixamSdkException {
  const TrackingException(super.code, super.message);
}

class DeviceException extends EixamSdkException {
  const DeviceException(super.code, super.message);

  const DeviceException.invalidPairingCode()
      : this('E_DEVICE_INVALID_PAIRING_CODE', 'The pairing code is not valid.');

  const DeviceException.invalidActivationCode()
      : this('E_DEVICE_INVALID_ACTIVATION_CODE', 'The activation code is not valid.');

  const DeviceException.notPaired()
      : this('E_DEVICE_NOT_PAIRED', 'The device must be paired before this action.');

  const DeviceException.notActivated()
      : this('E_DEVICE_NOT_ACTIVATED', 'The device must be activated before this action.');
}

class ContactsException extends EixamSdkException {
  const ContactsException(super.code, super.message);
}

class DeathManException extends EixamSdkException {
  const DeathManException(super.code, super.message);
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
