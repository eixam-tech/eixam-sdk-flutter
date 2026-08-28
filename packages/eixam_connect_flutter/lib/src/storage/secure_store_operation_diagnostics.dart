import 'package:flutter/foundation.dart';

enum SecureStoreOperation {
  sessionRead('session_read'),
  sessionWrite('session_write'),
  sessionWriteVerifyRead('session_write_verify_read'),
  sessionDelete('session_delete'),
  sosLifecycleRead('sos_lifecycle_read'),
  sosLifecycleDelete('sos_lifecycle_delete');

  const SecureStoreOperation(this.label);

  final String label;
}

void reportSecureStoreOperationFailure(
  SecureStoreOperation operation,
  Object error,
) {
  try {
    debugPrint(
      'SECURE_STORE_OPERATION_FAILED operation=${operation.label} '
      'reason=${error.runtimeType}',
    );
  } catch (_) {
    // Diagnostics must never alter secure-storage failure propagation.
  }
}

void reportSecureSessionRecovery() {
  try {
    debugPrint(
      'SECURE_SESSION_RECOVERY stage=persisted_session_read '
      'reason=entry_unreadable action=deleted_stale_entry',
    );
  } catch (_) {
    // Diagnostics must never alter secure-session recovery.
  }
}
