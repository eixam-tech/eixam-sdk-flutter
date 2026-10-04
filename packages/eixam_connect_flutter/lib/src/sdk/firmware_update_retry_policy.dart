import 'package:eixam_connect_core/eixam_connect_core.dart';

/// A terminal attempt may be replaced only after SDK device verification.
/// In-flight and recovery sessions must retain their existing ownership.
bool canRetryFirmwareAfterSourceVerification(FirmwareUpdateSession session) =>
    (!session.nativeTransferEngaged ||
        session.nextAction == FirmwareUpdateNextAction.retryTransfer ||
        session.nextAction == FirmwareUpdateNextAction.retryDownload ||
        session.completedAt != null) &&
    !session.requiresRecovery &&
    (session.nextAction == FirmwareUpdateNextAction.retry ||
        session.nextAction == FirmwareUpdateNextAction.retryTransfer ||
        session.nextAction == FirmwareUpdateNextAction.retryDownload ||
        session.nextAction == FirmwareUpdateNextAction.startTransfer ||
        !session.nativeTransferEngaged) &&
    (session.state == FirmwareUpdateState.failed ||
        session.state == FirmwareUpdateState.cancelled ||
        session.state == FirmwareUpdateState.blocked ||
        session.state == FirmwareUpdateState.readyToTransfer ||
        session.state == FirmwareUpdateState.downloading ||
        session.state == FirmwareUpdateState.verifying ||
        session.state == FirmwareUpdateState.idle);
