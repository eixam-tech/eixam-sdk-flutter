import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import 'meshtastic_gatt_response.dart';

import '../diagnostics/security_diagnostics_redactor.dart';
import 'ble_debug_registry.dart';
import 'meshtastic_ble_protocol.dart';
import 'meshtastic_phone_api_codec.dart';

abstract interface class MeshtasticMetadataProbe {
  /// [timeout] bounds metadata responses after the request, independently of
  /// connection, notification setup and Android user-mediated bonding.
  Future<MeshtasticProbeResult> inspect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 8),
  });
}

final class MeshtasticProbeResult {
  const MeshtasticProbeResult({
    required this.hardwareModel,
    this.firmwareVersion,
    this.nodeNumber,
    this.hardwareMac,
    this.batteryPercentage,
  });

  final int hardwareModel;
  final String? firmwareVersion;
  final int? nodeNumber;
  final String? hardwareMac;
  final int? batteryPercentage;
}

final class MeshtasticDeviceUnavailableException implements Exception {
  const MeshtasticDeviceUnavailableException();
}

/// A transport boundary for testing the actual inspection lifecycle.
abstract interface class MeshtasticInspectionTransport {
  bool get isConnected;
  Stream<BluetoothBondState>? get bondStates;
  Stream<List<int>> get frames;
  bool get hasRequiredCharacteristics;
  bool get hasBattery;
  Future<void> connect();
  Future<void> discoverServices();
  Future<int?> readBattery();
  Future<void> enableNotifications();
  Future<void> requestMetadata(List<int> bytes);
  Future<List<int>> readMetadata();

  /// Must bypass the BLE operation queue, interrupt pending operations, and
  /// complete only after the native connection has been released.
  Future<void> disconnect();

  /// Settle/cancel only bonding started by this inspection, preserving bonds.
  Future<BluetoothBondState?> finishBonding();
}

final class MeshtasticInspectionException implements Exception {
  const MeshtasticInspectionException(this.failure, [this.cause]);
  final DeviceMigrationInspectionFailure failure;
  final Object? cause;
}

/// Cancelling wakes the current stage; the result awaits transport cleanup.
final class MeshtasticInspectionCancellation {
  final Completer<void> _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

final class FlutterBlueMeshtasticMetadataProbe
    implements MeshtasticMetadataProbe {
  FlutterBlueMeshtasticMetadataProbe({
    MeshtasticPhoneApiCodec codec = const MeshtasticPhoneApiCodec(),
    MeshtasticInspectionTransport Function(String)? transportFactory,
    this.connectionTimeout = const Duration(seconds: 10),
    this.serviceTimeout = const Duration(seconds: 10),
    this.batteryTimeout = const Duration(seconds: 3),
    this.notificationTimeout = const Duration(seconds: 30),
    this.requestTimeout = const Duration(seconds: 5),
    this.cancellation,
  }) : _codec = codec,
       _transportFactory =
           transportFactory ?? _FlutterBlueInspectionTransport.new;

  static final Guid serviceUuid = Guid(MeshtasticBleProtocol.serviceUuid);
  static final Guid toRadioUuid = Guid('F75C76D2-129E-4DAD-A1DD-7866124401E7');
  static final Guid fromRadioUuid = Guid(
    '2C55E69E-4993-11ED-B878-0242AC120002',
  );
  static final Guid fromNumUuid = Guid('ED9DA18C-A800-4F66-A670-AA7547E34453');
  static final Guid batteryServiceUuid = Guid('180F');
  static final Guid batteryLevelUuid = Guid('2A19');

  final MeshtasticPhoneApiCodec _codec;
  final MeshtasticInspectionTransport Function(String) _transportFactory;
  final Duration connectionTimeout;
  final Duration serviceTimeout;
  final Duration batteryTimeout;
  final Duration notificationTimeout;
  final Duration requestTimeout;
  final MeshtasticInspectionCancellation? cancellation;

  @override
  Future<MeshtasticProbeResult> inspect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (deviceId.isEmpty || deviceId != deviceId.trim()) {
      throw const FormatException('Invalid BLE platform identifier.');
    }
    return _InspectionOperation(
      transport: _transportFactory(deviceId),
      probe: this,
      deviceId: deviceId,
      metadataTimeout: timeout,
    ).run();
  }
}

final class _InspectionOperation {
  _InspectionOperation({
    required this.transport,
    required this.probe,
    required this.deviceId,
    required this.metadataTimeout,
  });
  final MeshtasticInspectionTransport transport;
  final FlutterBlueMeshtasticMetadataProbe probe;
  final String deviceId;
  final Duration metadataTimeout;
  final Set<Future<void>> _pending = {};
  StreamSubscription<BluetoothBondState>? _bondSubscription;
  Completer<void>? _initialBond;
  StreamSubscription<List<int>>? _frameSubscription;
  BluetoothBondState? _bondState;
  bool _sawBonding = false;
  final Completer<void> _bondFailed = Completer<void>();
  bool _terminal = false;
  bool _ownsConnection = false;
  Timer? _pollTimer;
  Completer<void>? _pollWake;
  int? _nodeNumber;
  int? _battery;
  final Map<int, String> _macs = {};
  MeshtasticProbeResult? _result;
  MeshtasticInspectionException? _metadataError;

  void _trace(String stage, {String? failureCode}) => safeSdkDebugPrint(
    'MIGRATION_INSPECTION_STAGE stage=$stage '
    'selectedMarker=${SecurityDiagnosticsRedactor.stableIdentifierMarker(deviceId)} '
    'bondState=${_bondState?.name ?? 'unavailable'} '
    'failureCode=${failureCode ?? 'none'}',
  );

  Future<T> _stage<T>(
    String stage,
    Duration deadline,
    DeviceMigrationInspectionFailure failure,
    Future<T> Function() action,
  ) async {
    if (_terminal || probe.cancellation?.isCancelled == true) {
      throw const MeshtasticInspectionException(
        DeviceMigrationInspectionFailure.cancelled,
      );
    }
    _trace(stage);
    // Keep the underlying future tracked even if the deadline wins. Cleanup
    // interrupts the native operation and awaits its settlement before return.
    final operation = Future<T>.sync(action);
    final settled = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    _pending.add(settled);
    unawaited(settled.then((_) => _pending.remove(settled)));
    final expired = Completer<T>();
    final timer = Timer(
      deadline,
      () => expired.completeError(
        MeshtasticInspectionException(
          stage == 'enablingNotifications'
              ? (_sawBonding
                    ? DeviceMigrationInspectionFailure.bondingTimedOut
                    : DeviceMigrationInspectionFailure
                          .notificationSetupTimedOut)
              : failure,
        ),
      ),
    );
    try {
      return await Future.any<T>([
        operation,
        expired.future,
        if (stage == 'enablingNotifications')
          _bondFailed.future.then<T>(
            (_) => throw const MeshtasticInspectionException(
              DeviceMigrationInspectionFailure.bondingFailed,
            ),
          ),
        if (probe.cancellation != null)
          probe.cancellation!._cancelled.future.then<T>(
            (_) => throw const MeshtasticInspectionException(
              DeviceMigrationInspectionFailure.cancelled,
            ),
          ),
      ]);
    } on MeshtasticInspectionException {
      rethrow;
    } catch (error) {
      final nativeTimeout =
          error is FlutterBluePlusException &&
          error.platform == ErrorPlatform.fbp &&
          error.code == FbpErrorCode.timeout.index;
      throw MeshtasticInspectionException(
        stage == 'enablingNotifications'
            ? (nativeTimeout
                  ? (_sawBonding
                        ? DeviceMigrationInspectionFailure.bondingTimedOut
                        : DeviceMigrationInspectionFailure
                              .notificationSetupTimedOut)
                  : (_sawBonding
                        ? DeviceMigrationInspectionFailure.bondingFailed
                        : DeviceMigrationInspectionFailure
                              .notificationSetupFailed))
            : stage == 'waitingForMetadata' && !nativeTimeout
            ? DeviceMigrationInspectionFailure.metadataReadFailed
            : failure,
        error,
      );
    } finally {
      timer.cancel();
    }
  }

  void _consume(List<int> payload) {
    if (_terminal ||
        payload.isEmpty ||
        _result != null ||
        _metadataError != null) {
      return;
    }
    try {
      final frame = probe._codec.decodeFromRadio(payload);
      _nodeNumber = frame.nodeNumber ?? _nodeNumber;
      final node = frame.nodeInfoNumber;
      final mac = frame.nodeInfoMac;
      if (node != null && mac != null) {
        _macs[node] = mac
            .map((v) => v.toRadixString(16).padLeft(2, '0').toUpperCase())
            .join(':');
      }
      if (frame.hardwareModel != null) {
        final version = frame.firmwareVersion?.trim();
        _result = MeshtasticProbeResult(
          hardwareModel: frame.hardwareModel!,
          firmwareVersion: version?.isEmpty == true ? null : version,
          nodeNumber: _nodeNumber,
          hardwareMac: _macs[_nodeNumber],
          batteryPercentage: _battery,
        );
      } else if (frame.configCompleteId ==
          MeshtasticPhoneApiCodec.configRequestId) {
        _metadataError = const MeshtasticInspectionException(
          DeviceMigrationInspectionFailure.malformedMetadata,
          FormatException('Device metadata was not provided.'),
        );
      }
    } catch (error) {
      _metadataError = MeshtasticInspectionException(
        DeviceMigrationInspectionFailure.malformedMetadata,
        error,
      );
    }
  }

  Future<MeshtasticProbeResult> _readMetadata() async {
    while (!_terminal) {
      if (_metadataError != null) {
        throw _metadataError!;
      }
      if (_result != null) return _result!;
      _consume(await transport.readMetadata());
      if (_metadataError != null) {
        throw _metadataError!;
      }
      if (_result != null) return _result!;
      if (_terminal) break;
      // Sequential polling: there can never be overlapping metadata reads.
      _pollWake = Completer<void>();
      _pollTimer = Timer(
        const Duration(milliseconds: 120),
        () => _pollWake!.complete(),
      );
      await _pollWake!.future;
      _pollTimer = null;
    }
    throw const MeshtasticInspectionException(
      DeviceMigrationInspectionFailure.cancelled,
    );
  }

  Future<MeshtasticProbeResult> run() async {
    if (transport.isConnected) {
      throw const MeshtasticInspectionException(
        DeviceMigrationInspectionFailure.connectionAlreadyOwned,
      );
    }
    try {
      final bonds = transport.bondStates;
      if (bonds != null) {
        final initialBond = Completer<void>();
        _initialBond = initialBond;
        _bondSubscription = bonds.listen(
          (state) {
            if (_terminal) return;
            _bondState = state;
            if (!initialBond.isCompleted) initialBond.complete();
            if (state == BluetoothBondState.bonding) {
              _sawBonding = true;
              _trace('waitingForBond');
            }
            if (_sawBonding &&
                state == BluetoothBondState.none &&
                !_bondFailed.isCompleted) {
              _bondFailed.complete();
            }
          },
          onError: (Object error) {
            if (!initialBond.isCompleted) initialBond.completeError(error);
            // A failed Android bond observer must not silently remove evidence.
            if (!_terminal) {
              _metadataError = MeshtasticInspectionException(
                DeviceMigrationInspectionFailure.bondingFailed,
                error,
              );
            }
            if (!_bondFailed.isCompleted) _bondFailed.complete();
          },
        );
        await _stage(
          'observingBondState',
          const Duration(seconds: 3),
          DeviceMigrationInspectionFailure.bondingFailed,
          () => initialBond.future,
        );
        if (_bondState == BluetoothBondState.bonding) {
          // A bond already in progress belongs to another operation. Never
          // cancel it as part of this inspection's cleanup.
          throw const MeshtasticInspectionException(
            DeviceMigrationInspectionFailure.connectionAlreadyOwned,
          );
        }
      }
      _ownsConnection = true; // Includes a partially completed connect.
      await _stage(
        'connecting',
        probe.connectionTimeout,
        DeviceMigrationInspectionFailure.connectionFailed,
        transport.connect,
      );
      await _stage(
        'discoveringServices',
        probe.serviceTimeout,
        DeviceMigrationInspectionFailure.serviceDiscoveryFailed,
        transport.discoverServices,
      );
      if (!transport.hasRequiredCharacteristics) {
        throw const MeshtasticInspectionException(
          DeviceMigrationInspectionFailure.serviceIncomplete,
        );
      }
      if (transport.hasBattery) {
        try {
          _battery = await _stage(
            'readingBattery',
            probe.batteryTimeout,
            DeviceMigrationInspectionFailure.batteryReadFailed,
            transport.readBattery,
          );
        } on MeshtasticInspectionException catch (error) {
          // A timed out native read needs interruption; do not proceed with it
          // still owning FlutterBluePlus's global mutex.
          if (error.cause == null || !transport.isConnected) {
            rethrow;
          }
          // A completed, failed battery read remains optional evidence.
          _trace('batteryUnavailable');
        }
      }
      _frameSubscription = transport.frames.listen(
        _consume,
        onError: (Object error) {
          if (!_terminal) {
            _metadataError = MeshtasticInspectionException(
              DeviceMigrationInspectionFailure.malformedMetadata,
              error,
            );
          }
        },
      );
      await _stage(
        'enablingNotifications',
        probe.notificationTimeout,
        DeviceMigrationInspectionFailure.notificationSetupFailed,
        transport.enableNotifications,
      );
      await _stage(
        'requestingMetadata',
        probe.requestTimeout,
        DeviceMigrationInspectionFailure.metadataRequestFailed,
        () {
          if (_metadataError != null) throw _metadataError!;
          if (_bondFailed.isCompleted) {
            throw const MeshtasticInspectionException(
              DeviceMigrationInspectionFailure.bondingFailed,
            );
          }
          return transport.requestMetadata(probe._codec.encodeConfigRequest());
        },
      );
      final result = await _stage(
        'waitingForMetadata',
        metadataTimeout,
        DeviceMigrationInspectionFailure.metadataTimedOut,
        _readMetadata,
      );
      _trace('verifying');
      return result;
    } on MeshtasticInspectionException catch (error) {
      _trace('failed', failureCode: error.failure.name);
      rethrow;
    } finally {
      _terminal = true;
      if (_initialBond?.isCompleted == false) _initialBond!.complete();
      _pollTimer?.cancel();
      if (_pollWake?.isCompleted == false) _pollWake!.complete();
      await _frameSubscription?.cancel();
      if (_ownsConnection) {
        _trace('disconnecting');
        try {
          // Do not queue behind the very CCCD/read operation being cancelled.
          await transport.disconnect();
          if (_sawBonding && _bondState != BluetoothBondState.bonded) {
            _trace('settlingBond');
            _bondState = await transport.finishBonding();
          }
        } catch (error) {
          // Still drain futures; never report successful inspection with a
          // connection whose release could not be confirmed.
          await Future.wait(_pending.toList());
          await _bondSubscription?.cancel();
          throw MeshtasticInspectionException(
            DeviceMigrationInspectionFailure.cleanupFailed,
            error,
          );
        }
      }
      await Future.wait(_pending.toList());
      await _bondSubscription?.cancel();
      _trace('cleanupCompleted');
    }
  }
}

final class _FlutterBlueInspectionTransport
    implements MeshtasticInspectionTransport {
  _FlutterBlueInspectionTransport(String id)
    : device = BluetoothDevice.fromId(id);
  final BluetoothDevice device;
  BluetoothCharacteristic? _toRadio;
  BluetoothCharacteristic? _fromRadio;
  BluetoothCharacteristic? _fromNum;
  BluetoothCharacteristic? _battery;
  bool _closed = false;
  final Set<void Function()> _interruptions = {};
  Future<T?> _native<T>(
    Stream<T> responses,
    Future<bool> Function() invoke, {
    bool checkConnected = true,
    bool responseOptional = false,
  }) async {
    if (_closed) {
      throw const MeshtasticInspectionException(
        DeviceMigrationInspectionFailure.cancelled,
      );
    }
    final request = MeshtasticGattResponse<T>(responses);
    // Attach the error handler before native invocation can emit a disconnect.
    final response = request.response;
    unawaited(
      response.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {},
      ),
    );
    void interrupt() => request.interrupt(
      const MeshtasticInspectionException(
        DeviceMigrationInspectionFailure.cancelled,
      ),
    );
    _interruptions.add(interrupt);
    final disconnects = device.connectionState.listen((state) {
      if (checkConnected && state == BluetoothConnectionState.disconnected) {
        request.interrupt(
          FlutterBluePlusException(
            ErrorPlatform.fbp,
            'inspectionGatt',
            FbpErrorCode.deviceIsDisconnected.index,
            'Device is disconnected',
          ),
        );
      }
    });
    try {
      final waits = await invoke();
      if (responseOptional && !waits) request.noResponseRequired();
      return await response;
    } finally {
      _interruptions.remove(interrupt);
      await disconnects.cancel();
      await request.close();
    }
  }

  bool _matches(BmCharacteristicData p, BluetoothCharacteristic c) =>
      p.remoteId == c.remoteId &&
      p.primaryServiceUuid == c.primaryServiceUuid &&
      p.serviceUuid == c.serviceUuid &&
      p.characteristicUuid == c.characteristicUuid &&
      p.instanceId == c.instanceId;
  void _check(bool success, int? code, String? message) {
    if (!success) throw StateError('GATT status=$code ${message ?? ''}');
  }

  Future<List<int>> _read(BluetoothCharacteristic c) async {
    final p = await _native(
      FlutterBluePlusPlatform.instance.onCharacteristicReceived.where(
        (p) => _matches(p, c),
      ),
      () => FlutterBluePlusPlatform.instance.readCharacteristic(
        BmReadCharacteristicRequest(
          remoteId: c.remoteId,
          primaryServiceUuid: c.primaryServiceUuid,
          serviceUuid: c.serviceUuid,
          characteristicUuid: c.characteristicUuid,
          instanceId: c.instanceId,
        ),
      ),
    );
    _check(p!.success, p.errorCode, p.errorString);
    return p.value;
  }

  Future<void> _notify(BluetoothCharacteristic c) async {
    final p = await _native(
      FlutterBluePlusPlatform.instance.onDescriptorWritten.where(
        (p) =>
            p.remoteId == c.remoteId &&
            p.primaryServiceUuid == c.primaryServiceUuid &&
            p.serviceUuid == c.serviceUuid &&
            p.characteristicUuid == c.characteristicUuid &&
            p.instanceId == c.instanceId &&
            p.descriptorUuid == Guid('2902'),
      ),
      () => FlutterBluePlusPlatform.instance.setNotifyValue(
        BmSetNotifyValueRequest(
          remoteId: c.remoteId,
          primaryServiceUuid: c.primaryServiceUuid,
          serviceUuid: c.serviceUuid,
          characteristicUuid: c.characteristicUuid,
          instanceId: c.instanceId,
          forceIndications: false,
          enable: true,
        ),
      ),
      responseOptional: true,
    );
    if (p != null) _check(p.success, p.errorCode, p.errorString);
  }

  @override
  bool get isConnected => device.isConnected;
  @override
  Stream<BluetoothBondState>? get bondStates =>
      !kIsWeb && Platform.isAndroid ? device.bondState : null;
  @override
  Stream<List<int>> get frames => _fromRadio!.onValueReceived;
  @override
  bool get hasRequiredCharacteristics => _toRadio != null && _fromRadio != null;
  @override
  bool get hasBattery => _battery != null;
  @override
  Future<void> connect() =>
      device.connect(timeout: const Duration(seconds: 10), mtu: null);
  @override
  Future<void> discoverServices() async {
    final response = await _native(
      FlutterBluePlusPlatform.instance.onDiscoveredServices.where(
        (p) => p.remoteId == device.remoteId,
      ),
      () => FlutterBluePlusPlatform.instance.discoverServices(
        BmDiscoverServicesRequest(remoteId: device.remoteId),
      ),
    );
    _check(response!.success, response.errorCode, response.errorString);
    final services = response.services
        .map(BluetoothService.fromProto)
        .where((s) => s.isPrimary);
    for (final service in services) {
      for (final c in service.characteristics) {
        if (service.uuid == FlutterBlueMeshtasticMetadataProbe.serviceUuid) {
          if (c.uuid == FlutterBlueMeshtasticMetadataProbe.toRadioUuid) {
            _toRadio = c;
          }
          if (c.uuid == FlutterBlueMeshtasticMetadataProbe.fromRadioUuid) {
            _fromRadio = c;
          }
          if (c.uuid == FlutterBlueMeshtasticMetadataProbe.fromNumUuid) {
            _fromNum = c;
          }
        } else if (service.uuid ==
                FlutterBlueMeshtasticMetadataProbe.batteryServiceUuid &&
            c.uuid == FlutterBlueMeshtasticMetadataProbe.batteryLevelUuid) {
          _battery = c;
        }
      }
    }
  }

  @override
  Future<int?> readBattery() async {
    final bytes = await _read(_battery!);
    return bytes.isNotEmpty && bytes.first <= 100 ? bytes.first : null;
  }

  @override
  Future<void> enableNotifications() async {
    if (_fromRadio!.properties.notify) {
      await _notify(_fromRadio!);
    }
    if (_closed) {
      throw const MeshtasticInspectionException(
        DeviceMigrationInspectionFailure.cancelled,
      );
    }
    if (_fromNum?.properties.notify == true) {
      await _notify(_fromNum!);
    }
  }

  @override
  Future<void> requestMetadata(List<int> bytes) async {
    final c = _toRadio!;
    final response = await _native(
      FlutterBluePlusPlatform.instance.onCharacteristicWritten.where(
        (p) => _matches(p, c),
      ),
      () => FlutterBluePlusPlatform.instance.writeCharacteristic(
        BmWriteCharacteristicRequest(
          remoteId: c.remoteId,
          primaryServiceUuid: c.primaryServiceUuid,
          serviceUuid: c.serviceUuid,
          characteristicUuid: c.characteristicUuid,
          instanceId: c.instanceId,
          writeType: c.properties.writeWithoutResponse
              ? BmWriteType.withoutResponse
              : BmWriteType.withResponse,
          allowLongWrite: false,
          value: bytes,
        ),
      ),
    );
    _check(response!.success, response.errorCode, response.errorString);
  }

  @override
  Future<List<int>> readMetadata() => _read(_fromRadio!);
  @override
  Future<void> disconnect() async {
    _closed = true;
    for (final interrupt in _interruptions.toList()) {
      interrupt();
    }
    if (device.isConnected) {
      await device.disconnect(queue: false, timeout: 10);
    } else {
      // Also cancels a partially completed connect. Avoid FlutterBluePlus's
      // uncancellable Stream.first when native GATT already disconnected.
      await FlutterBluePlusPlatform.instance.disconnect(
        BmDisconnectRequest(remoteId: device.remoteId),
      );
    }
    if (device.isConnected) {
      throw StateError('Inspection connection remains connected.');
    }
  }

  @override
  Future<BluetoothBondState?> finishBonding() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    final response = MeshtasticGattResponse<BmBondStateResponse>(
      FlutterBluePlusPlatform.instance.onBondStateChanged.where(
        (p) =>
            p.remoteId == device.remoteId &&
            p.bondState != BmBondStateEnum.bonding,
      ),
      timeout: const Duration(seconds: 5),
    );
    unawaited(
      response.response.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {},
      ),
    );
    try {
      // Query native state instead of trusting a delayed cached broadcast.
      final state = await FlutterBluePlusPlatform.instance.getBondState(
        BmBondStateRequest(remoteId: device.remoteId),
      );
      if (state.bondState != BmBondStateEnum.bonding) {
        response.noResponseRequired();
      } else {
        final waits =
            await const MethodChannel(
              'dev.eixam.connect.flutter/meshtastic_inspection',
            ).invokeMethod<bool>('cancelPendingBond', {
              'deviceId': device.remoteId.str,
            });
        if (waits != true) response.noResponseRequired();
      }
      await response.response;
      final finalState = await FlutterBluePlusPlatform.instance.getBondState(
        BmBondStateRequest(remoteId: device.remoteId),
      );
      if (finalState.bondState == BmBondStateEnum.bonding) {
        throw StateError('Inspection bond remains in progress.');
      }
      return finalState.bondState == BmBondStateEnum.bonded
          ? BluetoothBondState.bonded
          : BluetoothBondState.none;
    } finally {
      await response.close();
    }
  }
}
