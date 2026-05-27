import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

class FirmwareDfuTransferRequest {
  const FirmwareDfuTransferRequest({
    required this.sessionId,
    required this.deviceId,
    required this.release,
    required this.artifactBytes,
  });

  final String sessionId;
  final String deviceId;
  final FirmwareRelease release;
  final List<int> artifactBytes;
}

class DfuProgress {
  const DfuProgress({
    required this.state,
    this.progressPercentage,
    this.bytesTransferred,
    this.totalBytes,
  });

  final FirmwareUpdateState state;
  final int? progressPercentage;
  final int? bytesTransferred;
  final int? totalBytes;
}

abstract class FirmwareDfuTransport {
  Future<void> start(FirmwareDfuTransferRequest request);
  Stream<DfuProgress> watchProgress(String sessionId);
  Future<void> cancel(String sessionId);
}

class UnsupportedFirmwareDfuTransport implements FirmwareDfuTransport {
  const UnsupportedFirmwareDfuTransport();

  static const failureCode = 'nativeDfuNotImplemented';

  @override
  Future<void> start(FirmwareDfuTransferRequest request) {
    throw const FirmwareUpdateException(
      failureCode,
      'Native Nordic/Adafruit DFU transport is not implemented yet.',
    );
  }

  @override
  Stream<DfuProgress> watchProgress(String sessionId) {
    return const Stream<DfuProgress>.empty();
  }

  @override
  Future<void> cancel(String sessionId) async {}
}
