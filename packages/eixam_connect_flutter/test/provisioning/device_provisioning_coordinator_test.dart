import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_network_psk_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/provisioning/device_assignment_verifier.dart';
import 'package:eixam_connect_flutter/src/provisioning/device_provisioning_coordinator.dart';
import 'package:eixam_connect_flutter/src/provisioning/strict_device_provisioning_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('already-provisioned exact assignment is ready without writes',
      () async {
    final harness = _Harness(initiallyProvisioned: true);
    final result = await harness.coordinator.ensureReady();

    expect(result.disposition, DeviceReadyDisposition.ready);
    expect(harness.commands, isEmpty);
    expect(harness.pskClient.requestCount, 0);
    expect(harness.registry.listCalls, 1);
    expect(harness.registry.upsertCalls, 0);
    expect(harness.diagnostics, contains('ASSIGNMENT_VERIFY result=matched'));
    await harness.dispose();
  });

  for (final testCase in <({String name, List<String> hardwareIds})>[
    (name: 'completely absent row', hardwareIds: <String>[]),
    (name: 'unowned current-app row is not listed', hardwareIds: <String>[]),
    (name: 'same-app another-user row is not listed', hardwareIds: <String>[]),
    (name: 'same node in another app is not listed', hardwareIds: <String>[]),
    (name: 'different hardware id', hardwareIds: <String>['7']),
    (
      name: 'MAC-like hardware id only',
      hardwareIds: <String>['AA:BB:CC:DD:EE:FF'],
    ),
    (name: 'malformed hardware id', hardwareIds: <String>[' 305419896 ']),
  ]) {
    test('already-provisioned ${testCase.name} is claimed then ready',
        () async {
      final harness = _Harness(
        initiallyProvisioned: true,
        assignmentHardwareIds: testCase.hardwareIds,
      );

      final result = await harness.coordinator.ensureReady();

      expect(result.disposition, DeviceReadyDisposition.ready);
      expect(harness.commands, isEmpty);
      expect(harness.pskClient.requestCount, 0);
      expect(harness.registry.listCalls, 2);
      expect(harness.registry.upsertCalls, 1);
      expect(
        harness.diagnostics,
        contains('ASSIGNMENT_CREATE reason=provisioned_assignment_missing'),
      );
      expect(
        harness.diagnostics,
        contains('ASSIGNMENT_READBACK result=matched'),
      );
      await harness.dispose();
    });
  }

  for (final testCase in <({String name, Object error})>[
    (
      name: 'backend timeout',
      error: TimeoutException('registry timeout'),
    ),
    (
      name: 'auth failure',
      error: const AuthException('E_TEST_AUTH', 'E_TEST_AUTH'),
    ),
    (
      name: 'repository failure',
      error: const DeviceException('E_TEST_REGISTRY', 'E_TEST_REGISTRY'),
    ),
  ]) {
    test('already-provisioned ${testCase.name} is assignment-unverified',
        () async {
      final harness = _Harness(
        initiallyProvisioned: true,
        registryError: testCase.error,
      );

      final result = await harness.coordinator.ensureReady();

      expect(
        result.disposition,
        DeviceReadyDisposition.provisionedAssignmentUnverified,
      );
      expect(result.failure, isNull);
      expect(harness.commands, isEmpty);
      expect(harness.registry.listCalls, 1);
      expect(harness.registry.upsertCalls, 0);
      expect(
        harness.diagnostics,
        contains('ASSIGNMENT_VERIFY result=backend_unavailable'),
      );
      await harness.dispose();
    });
  }

  test('exact assignment among multiple registered devices is ready', () async {
    final harness = _Harness(
      initiallyProvisioned: true,
      assignmentHardwareIds: const <String>[
        '7',
        '305419896',
        'AA:BB:CC:DD:EE:FF',
      ],
    );

    expect(
      (await harness.coordinator.ensureReady()).disposition,
      DeviceReadyDisposition.ready,
    );
    expect(harness.registry.listCalls, 1);
    expect(harness.registry.upsertCalls, 0);
    await harness.dispose();
  });

  test('fresh provisioning creates and reads back assignment', () async {
    final harness = _Harness(assignmentHardwareIds: const <String>[]);

    final result = await harness.coordinator.ensureReady();

    expect(
      result.disposition,
      DeviceReadyDisposition.ready,
    );
    expect(harness.commands, isNotEmpty);
    expect(harness.rebootCount, 1);
    expect(harness.runtimeReadCount, 2);
    expect(harness.registry.listCalls, 1);
    expect(harness.registry.upsertCalls, 1);
    expect(
      harness.diagnostics,
      contains('ASSIGNMENT_CREATE result=success'),
    );
    expect(
      harness.diagnostics,
      contains('ASSIGNMENT_READBACK result=matched'),
    );
    await harness.dispose();
  });

  test('fresh provisioning assignment failure remains unverified', () async {
    final harness = _Harness(
      assignmentHardwareIds: const <String>[],
      assignmentCreateError: StateError('assignment failed'),
    );

    final result = await harness.coordinator.ensureReady();

    expect(
      result.disposition,
      DeviceReadyDisposition.provisionedAssignmentUnverified,
    );
    expect(harness.rebootCount, 1);
    expect(harness.registry.upsertCalls, 1);
    expect(harness.registry.listCalls, 0);
    expect(
      harness.diagnostics,
      contains('ASSIGNMENT_CREATE result=failed'),
    );
    final commandCount = harness.commands.length;
    final retry = await harness.coordinator.ensureReady();
    expect(
      retry.disposition,
      DeviceReadyDisposition.provisionedAssignmentUnverified,
    );
    expect(harness.commands.length, commandCount);
    expect(harness.registry.upsertCalls, 2);
    await harness.dispose();
  });

  test('fresh provisioning assignment response mismatch fails closed',
      () async {
    final harness = _Harness(
      assignmentHardwareIds: const <String>[],
      assignmentCreateResponseHardwareId: '7',
    );

    final result = await harness.coordinator.ensureReady();

    expect(
      result.disposition,
      DeviceReadyDisposition.provisionedAssignmentUnverified,
    );
    expect(harness.registry.upsertCalls, 1);
    expect(harness.registry.listCalls, 0);
    await harness.dispose();
  });

  test('fresh provisioning missing read-back remains unverified', () async {
    final harness = _Harness(
      assignmentHardwareIds: const <String>[],
      persistCreatedAssignment: false,
    );

    final result = await harness.coordinator.ensureReady();

    expect(
      result.disposition,
      DeviceReadyDisposition.provisionedAssignmentUnverified,
    );
    expect(harness.registry.upsertCalls, 1);
    expect(harness.registry.listCalls, 1);
    expect(
      harness.diagnostics,
      contains('ASSIGNMENT_READBACK result=not_found'),
    );
    await harness.dispose();
  });

  test('assignment is not read before live provisioned state is established',
      () async {
    final harness = _Harness(liveFirmwareVersion: '2.7.31');

    final result = await harness.coordinator.ensureReady();

    expect(result.failure?.code, DeviceReadyFailureCode.firmwareUpdateRequired);
    expect(harness.registry.listCalls, 0);
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
    expect(harness.reconnectOwnershipAcquireCount, 1);
    expect(harness.reconnectOwnershipReleaseCount, 1);
    expect(harness.reconnectOwnershipHeld, isFalse);
    expect(harness.rebootBoundaryEvents,
        <String>['acquire', 'reboot', 'reconnect', 'release']);
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

  test('firmware policy accepts established certified version forms', () {
    const policy = ProvisioningFirmwarePolicy.current();
    expect(policy.supports('2.7.31'), isFalse);
    expect(policy.supports('2.7.37'), isTrue);
    expect(policy.supports('2.7.37.4ef9d04'), isTrue);
    expect(policy.supports('v2.7.37'), isTrue);
    expect(policy.supports('2.7.37+4ef9d04'), isTrue);
    expect(policy.supports('2.7.37-4ef9d04'), isTrue);
    expect(policy.supports('2.8.0'), isTrue);
    expect(policy.supports(null), isFalse);
  });

  test('firmware policy rejects malformed decorated versions', () {
    const policy = ProvisioningFirmwarePolicy.current();
    for (final version in <String>[
      '',
      'unreadable',
      'release-2.7.37',
      '2.7',
      '2.7.37.',
      '2.7.37.not-a-hash',
      '2.7.37+',
      '2.7.37-',
    ]) {
      expect(policy.supports(version), isFalse, reason: version);
    }
  });

  test('physical dotted build passes the live provisioning firmware gate',
      () async {
    final harness = _Harness(liveFirmwareVersion: '2.7.37.4ef9d04');
    final states = <DeviceProvisioningState>[];
    final subscription = harness.coordinator.watchState().listen(states.add);

    final result = await harness.coordinator.ensureReady();
    await Future<void>.delayed(Duration.zero);

    expect(result.isReady, isTrue);
    expect(result.failure, isNull);
    expect(
      states.map((state) => state.phase),
      isNot(contains(DeviceProvisioningPhase.firmwareUpdateRequired)),
    );
    await subscription.cancel();
    await harness.dispose();
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
    expect(harness.reconnectOwnershipHeld, isFalse);
    expect(harness.reconnectOwnershipReleaseCount, 1);
    expect(
      harness.diagnostics,
      contains('PROVISIONING_REBOOT failure_code=reconnectFailed'),
    );
    await harness.dispose();
  });

  test('reboot failure releases reconnect ownership', () async {
    final harness = _Harness(rebootFails: true);
    final result = await harness.coordinator.ensureReady();

    expect(result.failure?.code, DeviceReadyFailureCode.rebootFailed);
    expect(harness.reconnectOwnershipHeld, isFalse);
    expect(harness.reconnectOwnershipReleaseCount, 1);
    expect(
      harness.diagnostics,
      contains('PROVISIONING_REBOOT failure_code=rebootFailed'),
    );
    await harness.dispose();
  });

  test('changed nodeId after reboot fails identity verification', () async {
    final harness = _Harness(finalNodeId: 7);
    final result = await harness.coordinator.ensureReady();

    expect(result.failure?.code, DeviceReadyFailureCode.identityMismatch);
    expect(result.failure?.retryable, isFalse);
    expect(harness.reconnectOwnershipHeld, isFalse);
    expect(harness.reconnectOwnershipReleaseCount, 1);
    await harness.dispose();
  });

  test('stale pre-reboot unprovisioned 0x23 cannot produce ready', () async {
    final harness = _Harness(finalProvisioned: false);
    final result = await harness.coordinator.ensureReady();

    expect(result.failure?.code, DeviceReadyFailureCode.verificationFailed);
    expect(harness.reconnectOwnershipHeld, isFalse);
    expect(harness.reconnectOwnershipReleaseCount, 1);
    await harness.dispose();
  });

  test('dispose during reboot releases reconnect ownership', () async {
    final harness = _Harness(blockReboot: true);
    final result = harness.coordinator.ensureReady();
    await harness.rebootBlocked.future;

    expect(harness.reconnectOwnershipHeld, isTrue);
    final dispose = harness.coordinator.dispose();
    harness.releaseReboot.complete();
    await dispose;

    expect((await result).failure?.code,
        DeviceReadyFailureCode.deviceCommunicationInterrupted);
    expect(harness.reconnectOwnershipHeld, isFalse);
    expect(harness.reconnectOwnershipReleaseCount, 1);
    expect(
      harness.diagnostics,
      contains(
        'PROVISIONING_REBOOT '
        'failure_code=deviceCommunicationInterrupted',
      ),
    );
    await harness.dispose(closeCoordinator: false);
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

  test('disconnect during reconnect wait does not cancel provisioning',
      () async {
    final reconnect = Completer<bool>();
    final harness = _Harness(reconnectCompleter: reconnect);
    final result = harness.coordinator.ensureReady();
    await harness.reconnectStarted.future;

    harness.statuses.add(harness.status(connected: false));
    await Future<void>.delayed(Duration.zero);
    reconnect.complete(true);

    expect((await result).isReady, isTrue);
    expect(harness.reconnectCount, 1);
    await harness.dispose();
  });

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
    this.rebootFails = false,
    this.blockReboot = false,
    this.reconnectCompleter,
    List<String>? assignmentHardwareIds,
    Object? registryError,
    Object? assignmentCreateError,
    String? assignmentCreateResponseHardwareId,
    bool persistCreatedAssignment = true,
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
    registry = _RegistryRepository(
      hardwareIds: assignmentHardwareIds ?? <String>[initialNodeId.toString()],
      error: registryError,
      createError: assignmentCreateError,
      createResponseHardwareId: assignmentCreateResponseHardwareId,
      persistCreatedAssignment: persistCreatedAssignment,
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
      assignmentVerifier: RegisteredDeviceAssignmentVerifier(
        repository: registry,
      ),
      assignmentCreator: RegisteredDeviceAssignmentCreator(
        repository: registry,
      ),
      backendUrl: 'https://api.staging.eixam.io',
      incomingPackets: packets.stream,
      deviceStatusChanges: statuses.stream,
      writeCommand: _write,
      reboot: () async {
        rebootBoundaryEvents.add('reboot');
        rebootCount++;
        if (blockReboot) {
          if (!rebootBlocked.isCompleted) rebootBlocked.complete();
          await releaseReboot.future;
        }
        if (rebootFails) throw const ProvisioningRebootException();
      },
      reconnectSameDevice: (deviceId) async {
        rebootBoundaryEvents.add('reconnect');
        reconnectCount++;
        if (!reconnectStarted.isCompleted) reconnectStarted.complete();
        if (reconnectCompleter != null) {
          return await reconnectCompleter!.future;
        }
        return reconnectSucceeds && deviceId == 'ble-device-1';
      },
      acquireReconnectOwnership: () async {
        rebootBoundaryEvents.add('acquire');
        reconnectOwnershipAcquireCount++;
        reconnectOwnershipHeld = true;
      },
      releaseReconnectOwnership: () {
        rebootBoundaryEvents.add('release');
        reconnectOwnershipReleaseCount++;
        reconnectOwnershipHeld = false;
      },
      diagnosticLog: diagnostics.add,
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
  final bool rebootFails;
  final bool blockReboot;
  final Completer<bool>? reconnectCompleter;
  final StreamController<List<int>> packets =
      StreamController<List<int>>.broadcast();
  final StreamController<DeviceStatus> statuses =
      StreamController<DeviceStatus>.broadcast();
  final List<EixamDeviceCommand> commands = <EixamDeviceCommand>[];
  final List<String> rebootBoundaryEvents = <String>[];
  late final _PskClient pskClient;
  late final _RegistryRepository registry;
  late final DeviceProvisioningCoordinator coordinator;
  int rebootCount = 0;
  int reconnectCount = 0;
  int reconnectOwnershipAcquireCount = 0;
  int reconnectOwnershipReleaseCount = 0;
  bool reconnectOwnershipHeld = false;
  int runtimeReadCount = 0;
  final List<String> diagnostics = <String>[];
  final Completer<void> writeBlocked = Completer<void>();
  final Completer<void> releaseWrite = Completer<void>();
  final Completer<void> rebootBlocked = Completer<void>();
  final Completer<void> releaseReboot = Completer<void>();
  final Completer<void> reconnectStarted = Completer<void>();

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

final class _RegistryRepository implements SdkDeviceRegistryRepository {
  _RegistryRepository({
    required List<String> hardwareIds,
    this.error,
    this.createError,
    this.createResponseHardwareId,
    this.persistCreatedAssignment = true,
  }) : devices = hardwareIds
            .map(
              (hardwareId) => BackendRegisteredDevice(
                id: 'device-$hardwareId',
                hardwareId: hardwareId,
                firmwareVersion: '2.7.37',
                hardwareModel: 'EIXAM R1',
                pairedAt: DateTime.utc(2026),
                createdAt: DateTime.utc(2026),
                updatedAt: DateTime.utc(2026),
              ),
            )
            .toList();

  final List<BackendRegisteredDevice> devices;
  final Object? error;
  final Object? createError;
  final String? createResponseHardwareId;
  final bool persistCreatedAssignment;
  int listCalls = 0;
  int upsertCalls = 0;

  @override
  Future<List<BackendRegisteredDevice>> listRegisteredDevices() async {
    listCalls++;
    final failure = error;
    if (failure != null) throw failure;
    return devices;
  }

  @override
  Future<void> removeRegisteredDevice(String deviceId) {
    throw UnimplementedError();
  }

  @override
  Future<BackendRegisteredDevice> upsertRegisteredDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  }) async {
    upsertCalls++;
    final failure = createError;
    if (failure != null) throw failure;
    final responseHardwareId = createResponseHardwareId ?? hardwareId;
    final device = BackendRegisteredDevice(
      id: 'device-created',
      hardwareId: responseHardwareId,
      firmwareVersion: firmwareVersion,
      hardwareModel: hardwareModel,
      pairedAt: pairedAt,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    if (persistCreatedAssignment) {
      devices
        ..removeWhere((item) => item.hardwareId == hardwareId)
        ..add(device);
    }
    return device;
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
