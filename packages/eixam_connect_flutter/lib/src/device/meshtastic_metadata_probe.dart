import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'meshtastic_phone_api_codec.dart';

abstract interface class MeshtasticMetadataProbe {
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

final class FlutterBlueMeshtasticMetadataProbe
    implements MeshtasticMetadataProbe {
  FlutterBlueMeshtasticMetadataProbe({
    MeshtasticPhoneApiCodec codec = const MeshtasticPhoneApiCodec(),
  }) : _codec = codec;

  static final Guid serviceUuid = Guid('6BA1B218-15A8-461F-9FA8-5DCAE273EAFD');
  static final Guid toRadioUuid = Guid('F75C76D2-129E-4DAD-A1DD-7866124401E7');
  static final Guid fromRadioUuid = Guid(
    '2C55E69E-4993-11ED-B878-0242AC120002',
  );
  static final Guid fromNumUuid = Guid('ED9DA18C-A800-4F66-A670-AA7547E34453');
  static final Guid batteryServiceUuid = Guid(
    '0000180F-0000-1000-8000-00805F9B34FB',
  );
  static final Guid batteryLevelUuid = Guid(
    '00002A19-0000-1000-8000-00805F9B34FB',
  );

  final MeshtasticPhoneApiCodec _codec;

  @override
  Future<MeshtasticProbeResult> inspect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final normalized = deviceId.trim();
    if (normalized.isEmpty) {
      throw const FormatException('Missing BLE platform identifier.');
    }
    return _inspect(BluetoothDevice.fromId(normalized)).timeout(timeout);
  }

  Future<MeshtasticProbeResult> _inspect(BluetoothDevice device) async {
    var connectedHere = false;
    BluetoothCharacteristic? fromRadio;
    BluetoothCharacteristic? fromNum;
    StreamSubscription<List<int>>? fromRadioSub;
    StreamSubscription<List<int>>? fromNumSub;
    Timer? pollTimer;
    final result = Completer<MeshtasticProbeResult>();
    int? nodeNumber;
    String? ownMac;
    int? batteryPercentage;
    final macsByNode = <int, String>{};
    var readInFlight = false;

    void consume(List<int> payload) {
      if (payload.isEmpty || result.isCompleted) return;
      try {
        final frame = _codec.decodeFromRadio(payload);
        nodeNumber = frame.nodeNumber ?? nodeNumber;
        final infoNode = frame.nodeInfoNumber;
        final infoMac = frame.nodeInfoMac;
        if (infoNode != null && infoMac != null) {
          macsByNode[infoNode] = _formatMac(infoMac);
        }
        if (nodeNumber != null) ownMac = macsByNode[nodeNumber!];
        final model = frame.hardwareModel;
        if (model != null) {
          result.complete(
            MeshtasticProbeResult(
              hardwareModel: model,
              firmwareVersion: frame.firmwareVersion?.trim().isEmpty == true
                  ? null
                  : frame.firmwareVersion?.trim(),
              nodeNumber: nodeNumber,
              hardwareMac: ownMac,
              batteryPercentage: batteryPercentage,
            ),
          );
        } else if (frame.configCompleteId ==
                MeshtasticPhoneApiCodec.configRequestId &&
            !result.isCompleted) {
          result.completeError(
            const FormatException('Device metadata was not provided.'),
          );
        }
      } catch (error, stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
      }
    }

    Future<void> readNext() async {
      if (readInFlight || result.isCompleted || fromRadio == null) return;
      readInFlight = true;
      try {
        consume(await fromRadio.read());
      } catch (error, stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
      } finally {
        readInFlight = false;
      }
    }

    try {
      final wasConnected = device.isConnected;
      if (!wasConnected) {
        await device.connect(timeout: const Duration(seconds: 10), mtu: null);
        connectedHere = true;
      }
      final services = await device.discoverServices(
        subscribeToServicesChanged: false,
      );
      BluetoothCharacteristic? toRadio;
      BluetoothCharacteristic? battery;
      for (final service in services) {
        if (service.uuid == serviceUuid) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid == toRadioUuid) toRadio = characteristic;
            if (characteristic.uuid == fromRadioUuid) {
              fromRadio = characteristic;
            }
            if (characteristic.uuid == fromNumUuid) fromNum = characteristic;
          }
        } else if (service.uuid == batteryServiceUuid) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid == batteryLevelUuid) {
              battery = characteristic;
            }
          }
        }
      }
      if (toRadio == null || fromRadio == null) {
        throw const FormatException(
          'Meshtastic PhoneAPI service is incomplete.',
        );
      }
      if (battery != null) {
        try {
          final value = await battery.read();
          if (value.isNotEmpty && value.first >= 0 && value.first <= 100) {
            batteryPercentage = value.first;
          }
        } catch (_) {
          // Battery is a safety input when available, not identity evidence.
        }
      }
      fromRadioSub = fromRadio.onValueReceived.listen(consume);
      if (fromRadio.properties.notify) await fromRadio.setNotifyValue(true);
      final fromNumCharacteristic = fromNum;
      if (fromNumCharacteristic?.properties.notify == true) {
        fromNumSub = fromNumCharacteristic!.onValueReceived.listen(
          (_) => readNext(),
        );
        await fromNumCharacteristic.setNotifyValue(true);
      }
      await toRadio.write(
        _codec.encodeConfigRequest(),
        withoutResponse: toRadio.properties.writeWithoutResponse,
      );
      await readNext();
      pollTimer = Timer.periodic(
        const Duration(milliseconds: 120),
        (_) => unawaited(readNext()),
      );
      return await result.future;
    } finally {
      pollTimer?.cancel();
      await fromRadioSub?.cancel();
      await fromNumSub?.cancel();
      try {
        if (fromRadio?.isNotifying == true) {
          await fromRadio!.setNotifyValue(false);
        }
      } catch (_) {}
      try {
        if (fromNum?.isNotifying == true) await fromNum!.setNotifyValue(false);
      } catch (_) {}
      if (connectedHere) {
        try {
          await device.disconnect();
        } catch (_) {}
      }
    }
  }

  String _formatMac(List<int> bytes) => bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}
