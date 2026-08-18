import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_network_psk_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/provisioning/device_provisioning_coordinator.dart';
import 'package:eixam_connect_flutter/src/provisioning/strict_device_provisioning_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('already-provisioned assignment is unverified and not rewritten',
      () async {
    final harness = _Harness(initiallyProvisioned: true);
    final result = await harness.coordinator.ensureReady();

    expect(result.isReady, isFalse);
    expect(result.disposition,
        DeviceReadyDisposition.provisionedAssignmentUnverified);
    expect(harness.commands, isEmpty);
    expect(harness.pskClient.requestCount, 0);
    await harness.dispose();
  });

  test('2.7.31 requires firmware update before provisioning writes', () async {
    final harness = _Harness(liveFirmwareVersion: '2.7.31');
    final states = <DeviceProvisioningState>[];
    final subscription = harness.coordinator.watchState().listen(states.add);

    final first = harness.coordinator.ensureReady();
    final concurrent = harness.coordinator.ensureReady();
    expect(identical(first, concurrent), isTrue);
    final result = await first;
    await Future<void>.delayed(Duration.zero);

    expect(result.failure?.code, DeviceReadyFailureCode.firmwareUpdateRequired);
    expect(harness.commands, isEmpty);
    expect(harness.pskClient.requestCount, 0);
    expect(states.map((state) => state.phase),
        contains(DeviceProvisioningPhase.firmwareUpdateRequired));
    await subscription.cancel();
    await harness.dispose();
  });

  test('canonical virgin flow orders SoftSIM, 0x20, 0x21 and reboot', () async {
    final harness = _Harness();
    final result = await harness.coordinator.ensureReady();

    expect(result.isReady, isTrue);
    final opcodes = harness.commands.map((command) => command.opcode).toList();
    expect(opcodes.first, 0x24);
    expect(opcodes.lastIndexOf(0x24), lessThan(opcodes.indexOf(0x20)));
    expect(opcodes.indexOf(0x20), lessThan(opcodes.indexOf(0x21)));
    expect(harness.rebootCount, 1);
    expect(harness.reconnectCount, 1);
    expect(
      harness.commands.where((command) => command.opcode == 0x24).every(
            (command) =>
                command.payloadSensitivity ==
                BleCommandPayloadSensitivity.secret,
          ),
      isTrue,
    );
    expect(
      harness.commands.where((command) => command.opcode == 0x24).every(
            (command) => command.bytes.every((byte) => byte == 0),
          ),
      isTrue,
    );
    await harness.dispose();
  });

  test('0x20 OK_NOCHANGE is semantic success under corrected contract',
      () async {
    final harness = _Harness(
      noChangeOpcode: 0x20,
    );
    expect((await harness.coordinator.ensureReady()).isReady, isTrue);
    await harness.dispose();
  });

  test('OK_NOCHANGE is rejected for opcode 0x21', () async {
    final harness = _Harness(noChangeOpcode: 0x21);
    final result = await harness.coordinator.ensureReady();

    expect(result.failure?.code,
        DeviceReadyFailureCode.deviceConfigurationRejected);
    await harness.dispose();
  });

  test('firmware policy accepts current baseline and rejects old or unreadable',
      () {
    const policy = ProvisioningFirmwarePolicy.current();
    expect(policy.supports('2.7.31'), isFalse);
    expect(policy.supports('2.7.37'), isTrue);
    expect(policy.supports('2.8.0'), isTrue);
    expect(policy.supports(null), isFalse);
    expect(policy.supports('unreadable'), isFalse);
  });

  for (final version in <String?>['unreadable', null]) {
    test(
        '${version ?? 'missing'} firmware metadata fails closed before '
        'mutating writes', () async {
      final harness = _Harness(liveFirmwareVersion: version);
      final result = await harness.coordinator.ensureReady();

      expect(
          result.failure?.code, DeviceReadyFailureCode.firmwareUpdateRequired);
      expect(harness.commands, isEmpty);
      expect(harness.pskClient.requestCount, 0);
      await harness.dispose();
    });
  }

  test('unsupported firmware has no legacy provisioning fallback', () async {
    final harness = _Harness(liveFirmwareVersion: '2.7.31');
    final result = await harness.coordinator.ensureReady();

    expect(result.failure?.code, DeviceReadyFailureCode.firmwareUpdateRequired);
    expect(harness.commands.map((command) => command.opcode), isEmpty);
    expect(harness.rebootCount, 0);
    await harness.dispose();
  });

  for (final opcode in <int>[0x24, 0x20, 0x21]) {
    test('opcode 0x${opcode.toRadixString(16)} REJECT is typed failure',
        () async {
      final harness = _Harness(rejectedOpcode: opcode);
      final result = await harness.coordinator.ensureReady();

      expect(result.failure?.code,
          DeviceReadyFailureCode.deviceConfigurationRejected);
      expect(result.failure?.retryable, isFalse);
      await harness.dispose();
    });
  }

  test('reconnect failure is retryable', () async {
    final harness = _Harness(reconnectSucceeds: false);
    final result = await harness.coordinator.ensureReady();

    expect(result.failure?.code, DeviceReadyFailureCode.reconnectFailed);
    expect(result.failure?.retryable, isTrue);
    await harness.dispose();
  });

  test('changed nodeId after reboot fails identity verification', () async {
    final harness = _Harness(finalNodeId: 7);
    final result = await harness.coordinator.ensureReady();

    expect(result.failure?.code, DeviceReadyFailureCode.identityMismatch);
    expect(result.failure?.retryable, isFalse);
    await harness.dispose();
  });

  test('stale pre-reboot unprovisioned 0x23 cannot produce ready', () async {
    final harness = _Harness(finalProvisioned: false);
    final result = await harness.coordinator.ensureReady();

    expect(result.failure?.code, DeviceReadyFailureCode.verificationFailed);
    await harness.dispose();
  });

  test('live unsupported firmware overrides supported cached metadata',
      () async {
    final harness = _Harness(
      liveFirmwareVersion: '2.7.31',
    );
    final result = await harness.coordinator.ensureReady();

    expect(result.failure?.code, DeviceReadyFailureCode.firmwareUpdateRequired);
    expect(harness.commands, isEmpty);
    expect(harness.pskClient.requestCount, 0);
    await harness.dispose();
  });

  test('nodeId maximum unsigned value is provisioned without truncation',
      () async {
    final harness = _Harness(
      initialNodeId: 0xffffffff,
      finalNodeId: 0xffffffff,
    );
    expect((await harness.coordinator.ensureReady()).isReady, isTrue);
    await harness.dispose();
  });

  test('ready state resets on disconnect', () async {
    final harness = _Harness();
    final states = <DeviceProvisioningState>[];
    final subscription = harness.coordinator.watchState().listen(states.add);
    expect((await harness.coordinator.ensureReady()).isReady, isTrue);

    harness.statuses.add(harness.status(connected: false));
    await Future<void>.delayed(Duration.zero);
    expect(states.last.phase, DeviceProvisioningPhase.idle);

    await subscription.cancel();
    await harness.dispose();
  });

  test('ready state resets on connected-device switch', () async {
    final harness = _Harness();
    final states = <DeviceProvisioningState>[];
    final subscription = harness.coordinator.watchState().listen(states.add);
    expect((await harness.coordinator.ensureReady()).isReady, isTrue);

    harness.statuses.add(harness.status(deviceId: 'ble-device-2'));
    await Future<void>.delayed(Duration.zero);
    expect(states.last.phase, DeviceProvisioningPhase.idle);
    await subscription.cancel();
    await harness.dispose();
  });

  for (final blockAt in <int>[1, 2]) {
    test(
        'dispose during ${blockAt == 1 ? 'BEGIN' : 'CHUNK'} stops all later writes',
        () async {
      final harness = _Harness(blockAtWrite: blockAt);
      final result = harness.coordinator.ensureReady();
      await harness.writeBlocked.future;
      final writesAtDispose = harness.commands.length;

      await harness.coordinator.dispose();
      harness.releaseWrite.complete();
      expect((await result).isReady, isFalse);
      expect(harness.commands, hasLength(writesAtDispose));
      expect(
        harness.commands.every(
          (command) => command.bytes.every((byte) => byte == 0),
        ),
        isTrue,
      );
      expect(
          harness.commands.any((command) => command.opcode == 0x20), isFalse);
      expect(harness.rebootCount, 0);
      await harness.dispose(closeCoordinator: false);
    });
  }

  test('wrong final platform identity fails before fresh 0x23 verification',
      () async {
    final harness = _Harness(finalDeviceId: 'ble-device-2');
    final result = await harness.coordinator.ensureReady();
    expect(result.failure?.code, DeviceReadyFailureCode.identityMismatch);
    expect(harness.runtimeReadCount, 1);
    await harness.dispose();
  });
}

final class _Harness {
  _Harness({
    this.initiallyProvisioned = false,
    this.rejectedOpcode,
    this.noChangeOpcode,
    this.reconnectSucceeds = true,
    this.finalNodeId = 305419896,
    this.finalProvisioned = true,
    this.liveFirmwareVersion = '2.7.37',
    this.initialNodeId = 305419896,
    this.finalDeviceId = 'ble-device-1',
    this.blockAtWrite,
  }) {
    pskClient = _PskClient();
    final session = SdkSessionContext()
      ..currentSession = const EixamSession.signed(
        appId: 'test-app',
        externalUserId: 'test-user',
        userHash: 'test-hash',
      );
    final pskSource = HttpSdkNetworkPskRemoteDataSource(
      transport: SdkHttpTransport(
        client: pskClient,
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.staging.eixam.io',
          websocketUrl: 'wss://mqtt.staging.eixam.io',
        ),
        sessionContext: session,
      ),
    );
    coordinator = DeviceProvisioningCoordinator(
      statusProvider: () async => _status(afterReboot: rebootCount > 0),
      liveStatusProvider: () async => _status(
        afterReboot: rebootCount > 0,
        firmwareVersion: liveFirmwareVersion,
      ),
      runtimeStatusProvider: () async => _runtime(afterReboot: rebootCount > 0),
      countryIsoProvider: () async => 'ES',
      pskSource: pskSource,
      configSource: const _ConfigSource(),
      backendUrl: 'https://api.staging.eixam.io',
      incomingPackets: packets.stream,
      deviceStatusChanges: statuses.stream,
      writeCommand: _write,
      reboot: () async => rebootCount++,
      reconnectSameDevice: (deviceId) async {
        reconnectCount++;
        return reconnectSucceeds && deviceId == 'ble-device-1';
      },
      firmwarePolicy: const ProvisioningFirmwarePolicy.current(),
      softSimRejectionObservationInterval: const Duration(milliseconds: 1),
    );
  }

  final bool initiallyProvisioned;
  final int? rejectedOpcode;
  final int? noChangeOpcode;
  final bool reconnectSucceeds;
  final int finalNodeId;
  final bool finalProvisioned;
  final String? liveFirmwareVersion;
  final int initialNodeId;
  final String finalDeviceId;
  final int? blockAtWrite;
  final StreamController<List<int>> packets =
      StreamController<List<int>>.broadcast();
  final StreamController<DeviceStatus> statuses =
      StreamController<DeviceStatus>.broadcast();
  final List<EixamDeviceCommand> commands = <EixamDeviceCommand>[];
  late final _PskClient pskClient;
  late final DeviceProvisioningCoordinator coordinator;
  int rebootCount = 0;
  int reconnectCount = 0;
  int runtimeReadCount = 0;
  final Completer<void> writeBlocked = Completer<void>();
  final Completer<void> releaseWrite = Completer<void>();

  DeviceStatus _status({
    required bool afterReboot,
    String? firmwareVersion = '2.7.37',
  }) =>
      DeviceStatus(
        deviceId: afterReboot ? finalDeviceId : 'ble-device-1',
        nodeId: afterReboot ? finalNodeId : initialNodeId,
        paired: true,
        activated: false,
        connected: true,
        provisioningStatus:
            (afterReboot ? finalProvisioned : initiallyProvisioned)
                ? DeviceProvisioningStatus.provisioned
                : DeviceProvisioningStatus.unprovisioned,
        firmwareVersion: firmwareVersion,
      );

  DeviceRuntimeStatus _runtime({required bool afterReboot}) {
    runtimeReadCount++;
    return DeviceRuntimeStatus(
      region: 3,
      modemPreset: 0,
      meshSpreadingFactor: 9,
      isProvisioned: afterReboot ? finalProvisioned : initiallyProvisioned,
      usePreset: false,
      txEnabled: afterReboot || initiallyProvisioned,
      inetOk: false,
      positionConfirmed: false,
      nodeId: afterReboot ? finalNodeId : initialNodeId,
      batteryPercent: 90,
      telIntervalSeconds: 120,
    );
  }

  DeviceStatus status({
    bool connected = true,
    String deviceId = 'ble-device-1',
  }) =>
      _status(afterReboot: true).copyWith(
        connected: connected,
        deviceId: deviceId,
      );

  Future<void> _write(EixamDeviceCommand command) async {
    commands.add(command);
    if (commands.length == blockAtWrite) {
      if (!writeBlocked.isCompleted) writeBlocked.complete();
      await releaseWrite.future;
    }
    final bytes = command.encode();
    final isCommit =
        command.opcode != 0x24 || (bytes.length == 2 && bytes[1] == 0x03);
    if (!isCommit) {
      return;
    }
    final result = command.opcode == rejectedOpcode
        ? 0x02
        : command.opcode == noChangeOpcode
            ? 0x01
            : 0x00;
    scheduleMicrotask(
      () => packets.add(<int>[
        0xe9,
        0x7a,
        1,
        command.opcode,
        result,
        command.opcode == 0x24 ? 3 : 0,
      ]),
    );
  }

  Future<void> dispose({bool closeCoordinator = true}) async {
    if (closeCoordinator) await coordinator.dispose();
    await packets.close();
    await statuses.close();
    pskClient.close();
  }
}

final class _ConfigSource implements StrictDeviceProvisioningConfigSource {
  const _ConfigSource();

  @override
  Future<StrictDeviceProvisioningConfig> fetch(
      {required String countryIso}) async {
    if (countryIso != 'ES') {
      throw const ProvisioningContractException();
    }
    return StrictDeviceProvisioningConfig.parse(<String, dynamic>{
      'lora_region_code': 3,
      'plan_verified': true,
      'region': 'EU868',
      'tel': <String, dynamic>{
        'freq_mhz': 866.5,
        'bw_khz': 250,
        'sf_default': 9,
        'cr': '4/5',
        'tx_power_uplink_dbm': 14,
      },
      'sos': <String, dynamic>{
        'freq_mhz': 869.4625,
        'bw_khz': 62.5,
        'sf': 12,
        'cr': '4/8',
        'tx_power_dbm': 22,
        'preamble_symbols': 8,
      },
    });
  }
}

final class _PskClient extends http.BaseClient {
  int requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    const body = '{"psk":"000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f",'
        '"algorithm":"AES-256","bytes":32,"scope":"app"}';
    return http.StreamedResponse(
      Stream<List<int>>.value(body.codeUnits),
      200,
      request: request,
    );
  }
}
