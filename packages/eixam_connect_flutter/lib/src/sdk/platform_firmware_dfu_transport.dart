import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../device/ble_debug_registry.dart';
import 'firmware_dfu_transport.dart';

class PlatformFirmwareDfuTransport implements FirmwareDfuTransport {
  PlatformFirmwareDfuTransport({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    Stream<dynamic> Function()? eventStreamFactory,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(_methodChannelName),
        _eventChannel = eventChannel ?? const EventChannel(_eventChannelName),
        _eventStreamFactory = eventStreamFactory;

  static const String _methodChannelName =
      'dev.eixam.connect_flutter/firmware_dfu/methods';
  static const String _eventChannelName =
      'dev.eixam.connect_flutter/firmware_dfu/events';

  /// Max silence between native DFU events before giving up. This is an
  /// *inactivity* window, not an absolute cap on the whole transfer: it re-arms
  /// on every native event, so a slow-but-progressing upload (e.g. a legacy
  /// bootloader capped at ATT MTU 23 with a low PRN, which can take 10–15 min
  /// for a ~600 KB image) is never killed mid-flight — only a genuine hang with
  /// no events at all trips it. A previous fixed 6-min absolute cap aborted
  /// healthy slow transfers, resetting the UI to "failed" while the native
  /// foreground service kept flashing in the background.
  static const Duration _nativeInactivityTimeout = Duration(minutes: 6);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final Stream<dynamic> Function()? _eventStreamFactory;

  Stream<dynamic>? _nativeEvents;
  final Map<String, String> _artifactPathsBySession = <String, String>{};

  @override
  Future<void> start(FirmwareDfuTransferRequest request) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      throw const FirmwareUpdateException(
        UnsupportedFirmwareDfuTransport.failureCode,
        'Native Nordic/Adafruit DFU transport is unavailable on this platform.',
      );
    }
    final firmwareZipPath = await _writeFirmwareZip(request);
    _artifactPathsBySession[request.sessionId] = firmwareZipPath;
    late final StreamSubscription<_NativeDfuEvent> terminalSub;
    final terminalCompleter = Completer<_NativeDfuEvent>();
    _NativeDfuEvent? lastEvent;
    Timer? inactivityTimer;
    // Re-armed on every native event and after the transfer starts. Only a full
    // window of silence (no progress/state events) completes the transfer with
    // a timeout error, so a slow-but-live upload keeps running.
    void armInactivityTimeout() {
      inactivityTimer?.cancel();
      inactivityTimer = Timer(_nativeInactivityTimeout, () {
        if (terminalCompleter.isCompleted) {
          return;
        }
        terminalCompleter.complete(
          _NativeDfuEvent(
            sessionId: request.sessionId,
            state: 'dfuError',
            errorCode: 'dfuTerminalTimeout',
            errorMessage: 'Native DFU reported no events for '
                '${_nativeInactivityTimeout.inMinutes} min. Last native state '
                'was ${lastEvent?.state ?? "unknown"}.',
            requiresRecovery: lastEvent?.requiresRecovery == true ||
                lastEvent?.state == 'deviceDisconnected',
          ),
        );
      });
    }

    terminalSub = _ensureNativeEvents()
        .map(_mapNativeEvent)
        .where((event) => event.sessionId == request.sessionId)
        .listen((event) {
      lastEvent = event;
      if (!event.isTerminal) {
        armInactivityTimeout();
      }
      if (event.isTerminal && !terminalCompleter.isCompleted) {
        terminalCompleter.complete(event);
      }
    });
    try {
      final raw = await _methodChannel
          .invokeMapMethod<String, dynamic>('startDfu', <String, dynamic>{
        'sessionId': request.sessionId,
        'deviceId': request.deviceId,
        'deviceRemoteId': request.deviceId,
        'firmwareZipPath': firmwareZipPath,
        'targetVersion': request.release.version,
        'releaseId': request.release.releaseId,
        'forceDfu': request.forceDfu,
        'enterDfuMode': !request.forceDfu,
      });
      final started = raw?['success'] == true || raw?['started'] == true;
      if (!started) {
        final startRequiresRecovery = raw?['requiresRecovery'] == true;
        throw FirmwareUpdateException(
          startRequiresRecovery
              ? 'recoveryRequired'
              : _nativeErrorCode(raw, fallback: 'dfuFailed'),
          _nativeErrorMessage(raw, fallback: 'Native DFU failed to start.'),
          requiresRecovery: startRequiresRecovery,
        );
      }
      // Arm the inactivity watchdog now that the native transfer is running;
      // each subsequent native event re-arms it, so it only fires on true
      // silence, never on a healthy slow transfer.
      armInactivityTimeout();
      final terminal = await terminalCompleter.future;
      if (terminal.isSuccess) {
        return;
      }
      safeSdkDebugPrint(
        'OTA_DFU_DART native terminal error '
        'sessionId=${request.sessionId} state=${terminal.state} '
        'code=${terminal.errorCode ?? "dfuFailed"} '
        'requiresRecovery=${terminal.requiresRecovery}',
      );
      throw FirmwareUpdateException(
        terminal.requiresRecovery
            ? 'recoveryRequired'
            : (terminal.errorCode ?? _terminalFailureCode(terminal.state)),
        terminal.errorMessage ?? 'Native DFU failed.',
        requiresRecovery: terminal.requiresRecovery,
      );
    } on PlatformException catch (error) {
      throw FirmwareUpdateException(
        _mapPlatformErrorCode(error.code),
        error.message ?? error.code,
      );
    } finally {
      inactivityTimer?.cancel();
      await terminalSub.cancel();
      await _deleteArtifactQuietly(request.sessionId);
    }
  }

  @override
  Stream<DfuProgress> watchProgress(String sessionId) {
    return _ensureNativeEvents()
        .map(_mapProgressEvent)
        .where((progress) => progress.sessionId == sessionId)
        .map((progress) => progress.progress);
  }

  @override
  Future<void> cancel(String sessionId) async {
    try {
      await _methodChannel.invokeMethod<void>('cancelDfu', <String, dynamic>{
        'sessionId': sessionId,
      });
    } on PlatformException catch (error) {
      throw FirmwareUpdateException(
        _mapPlatformErrorCode(error.code),
        error.message ?? error.code,
      );
    } finally {
      await _deleteArtifactQuietly(sessionId);
    }
  }

  Future<String> _writeFirmwareZip(FirmwareDfuTransferRequest request) async {
    final tempDir = Directory.systemTemp.createTempSync('eixam_dfu_');
    final file = File(
      '${tempDir.path}${Platform.pathSeparator}'
      '${request.sessionId}_${request.release.version}.zip',
    );
    await file.writeAsBytes(request.artifactBytes, flush: true);
    return file.path;
  }

  Future<void> _deleteArtifactQuietly(String sessionId) async {
    final path = _artifactPathsBySession.remove(sessionId);
    if (path == null) {
      return;
    }
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
      final parent = file.parent;
      if (await parent.exists()) {
        await parent.delete();
      }
    } catch (_) {}
  }

  Stream<dynamic> _ensureNativeEvents() {
    return _nativeEvents ??=
        (_eventStreamFactory?.call() ?? _eventChannel.receiveBroadcastStream())
            .asBroadcastStream();
  }

  _NativeDfuEvent _mapNativeEvent(dynamic event) {
    final raw = Map<Object?, Object?>.from(event as Map<Object?, Object?>);
    return _NativeDfuEvent(
      sessionId: (raw['sessionId'] as String?)?.trim() ?? '',
      state: (raw['state'] as String?)?.trim() ?? '',
      deviceAddress: _nonEmptyString(raw['deviceAddress']),
      progressPercentage: (raw['progressPct'] as num?)?.toInt(),
      errorCode: _nonEmptyString(raw['errorCode']),
      errorMessage: _nonEmptyString(raw['errorMessage']),
      requiresRecovery: raw['requiresRecovery'] == true,
      emittedAtMillis: (raw['emittedAtMillis'] as num?)?.toInt(),
      completedAtMillis: (raw['completedAtMillis'] as num?)?.toInt(),
    );
  }

  String? _nonEmptyString(Object? value) {
    final text = (value as String?)?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  _NativeDfuProgress _mapProgressEvent(dynamic event) {
    final native = _mapNativeEvent(event);
    return _NativeDfuProgress(
      sessionId: native.sessionId,
      progress: DfuProgress(
        state: _mapNativeState(
          native.state,
          errorCode: native.errorCode,
          requiresRecovery: native.requiresRecovery,
        ),
        progressPercentage: native.progressPercentage,
      ),
    );
  }

  FirmwareUpdateState _mapNativeState(
    String? state, {
    String? errorCode,
    required bool requiresRecovery,
  }) {
    if (requiresRecovery) {
      return FirmwareUpdateState.recoveryRequired;
    }
    if (errorCode != null && errorCode.isNotEmpty) {
      return FirmwareUpdateState.failed;
    }
    return switch (state) {
      'queued' ||
      'connecting' ||
      'connected' ||
      'dfuProcessStarting' ||
      'enablingDfuMode' ||
      'starting' ||
      'uploading' =>
        FirmwareUpdateState.transferring,
      'firmwareValidating' => FirmwareUpdateState.transferring,
      'deviceDisconnecting' ||
      'deviceDisconnected' ||
      'dfuCompleted' =>
        FirmwareUpdateState.reconnecting,
      'dfuAborted' => FirmwareUpdateState.cancelled,
      'dfuError' => FirmwareUpdateState.failed,
      'downloading' => FirmwareUpdateState.downloading,
      'verifying' => FirmwareUpdateState.verifying,
      'readyToTransfer' => FirmwareUpdateState.readyToTransfer,
      'transferring' => FirmwareUpdateState.transferring,
      'reconnecting' => FirmwareUpdateState.reconnecting,
      'completed' => FirmwareUpdateState.reconnecting,
      'cancelled' => FirmwareUpdateState.cancelled,
      'recoveryRequired' => FirmwareUpdateState.recoveryRequired,
      'failed' => FirmwareUpdateState.failed,
      _ => FirmwareUpdateState.transferring,
    };
  }

  String _terminalFailureCode(String state) {
    return switch (state) {
      'dfuAborted' || 'cancelled' => 'cancelled',
      'dfuError' || 'failed' => 'dfuFailed',
      'recoveryRequired' => 'recoveryRequired',
      _ => 'dfuFailed',
    };
  }

  String _nativeErrorCode(
    Map<String, dynamic>? raw, {
    required String fallback,
  }) {
    return (raw?['errorCode'] as String?)?.trim().isNotEmpty == true
        ? (raw!['errorCode'] as String).trim()
        : fallback;
  }

  String _nativeErrorMessage(
    Map<String, dynamic>? raw, {
    required String fallback,
  }) {
    return (raw?['errorMessage'] as String?)?.trim().isNotEmpty == true
        ? (raw!['errorMessage'] as String).trim()
        : fallback;
  }

  String _mapPlatformErrorCode(String code) {
    return switch (code) {
      'alreadyRunning' => 'alreadyRunning',
      'bluetoothDisabled' => 'bluetoothDisabled',
      'missingPermission' => 'missingPermission',
      'deviceNotFound' => 'deviceNotFound',
      'fileMissing' => 'artifactMissing',
      'invalidZip' => 'invalidZip',
      'cancelled' => 'cancelled',
      'deviceDisconnected' => 'deviceDisconnected',
      'recoveryRequired' => 'recoveryRequired',
      _ => code.isEmpty ? 'dfuFailed' : code,
    };
  }
}

class _NativeDfuEvent {
  const _NativeDfuEvent({
    required this.sessionId,
    required this.state,
    this.deviceAddress,
    this.progressPercentage,
    this.errorCode,
    this.errorMessage,
    this.requiresRecovery = false,
    this.emittedAtMillis,
    this.completedAtMillis,
  });

  final String sessionId;
  final String state;
  final String? deviceAddress;
  final int? progressPercentage;
  final String? errorCode;
  final String? errorMessage;
  final bool requiresRecovery;
  final int? emittedAtMillis;
  final int? completedAtMillis;

  bool get isSuccess => state == 'dfuCompleted' || state == 'completed';

  bool get isTerminal =>
      isSuccess ||
      state == 'dfuAborted' ||
      state == 'dfuError' ||
      state == 'cancelled' ||
      state == 'failed' ||
      state == 'recoveryRequired';
}

class _NativeDfuProgress {
  const _NativeDfuProgress({required this.sessionId, required this.progress});

  final String sessionId;
  final DfuProgress progress;
}
