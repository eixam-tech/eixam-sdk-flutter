import 'dart:collection';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_incoming_event.dart';
import '../device/eixam_position_sample_identity.dart';
import '../device/eixam_position_backlog_packet.dart';

class DevicePositionNormalizationResult {
  const DevicePositionNormalizationResult({
    required this.batch,
    required this.duplicateCount,
  });

  final EixamDevicePositionBatch? batch;
  final int duplicateCount;
}

/// Converts connected-device TEL deliveries into a transport-neutral stream of
/// novel position batches.
class DevicePositionBatchNormalizer {
  DevicePositionBatchNormalizer({
    this.maximumDevices = 4,
    this.maximumRecordIdentitiesPerDevice = 8192,
    this.maximumRecentWireIdentitiesPerDevice = 64,
    this.crossTransportWindow = const Duration(seconds: 10),
  });

  final int maximumDevices;
  final int maximumRecordIdentitiesPerDevice;
  final int maximumRecentWireIdentitiesPerDevice;
  final Duration crossTransportWindow;

  final LinkedHashMap<String, _DeviceDedupState> _states =
      LinkedHashMap<String, _DeviceDedupState>();

  int get cachedDeviceCount => _states.length;

  int get largestRecordIdentityCount => _states.values.fold<int>(
        0,
        (largest, state) => state.recordIdentities.length > largest
            ? state.recordIdentities.length
            : largest,
      );

  EixamDevicePositionBatch? normalize(BleIncomingEvent event) {
    final liveBatch = event.telLiveBatchPacket;
    if (liveBatch != null) {
      return _normalizeLiveBatch(event, liveBatch.batch);
    }

    final telPacket = event.telPacket;
    if (event.type != BleIncomingEventType.telPosition || telPacket == null) {
      return null;
    }
    return _normalizeClassicTel(event);
  }

  DevicePositionNormalizationResult normalizeBacklog(
    BleIncomingEvent event,
    EixamPositionBacklogChunk chunk,
  ) {
    final sample = chunk.batch.samples.single;
    final state = _stateFor(event, chunk.telPacket.nodeId);
    if (state.recordIdentities.containsKey(sample.stableSampleKey)) {
      return const DevicePositionNormalizationResult(
        batch: null,
        duplicateCount: 1,
      );
    }
    state.rememberRecordIdentity(
      sample.stableSampleKey,
      maximumRecordIdentitiesPerDevice,
      receivedAt: event.receivedAt,
    );
    return DevicePositionNormalizationResult(
      batch: EixamDevicePositionBatch(
        samples: chunk.batch.samples,
        receivedAt: chunk.batch.receivedAt,
        source: chunk.batch.source,
        delivery: EixamDevicePositionDelivery.recovered,
        deviceIdentity: _deviceIdentity(event),
      ),
      duplicateCount: 0,
    );
  }

  EixamDevicePositionBatch? _normalizeLiveBatch(
    BleIncomingEvent event,
    EixamDevicePositionBatch batch,
  ) {
    final liveBatch = event.telLiveBatchPacket!;
    final novel = <EixamDevicePositionSample>[];
    for (var index = 0; index < batch.samples.length; index++) {
      final sample = batch.samples[index];
      final packet = liveBatch.telPackets[index];
      final state = _stateFor(event, packet.nodeId);
      final recordIdentity = sample.stableSampleKey;
      if (state.recordIdentities.containsKey(recordIdentity)) {
        continue;
      }

      final wireFingerprint =
          EixamPositionSampleIdentity.telWireFingerprint(packet.rawBytes);
      final repeatedAcrossTransport = state.wasRecentlySeenFromOtherTransport(
        wireFingerprint,
        transport: _PositionTransport.liveBatch,
        receivedAt: batch.receivedAt,
        window: crossTransportWindow,
      );
      state.rememberRecordIdentity(
        recordIdentity,
        maximumRecordIdentitiesPerDevice,
      );
      state.rememberWire(
        wireFingerprint,
        transport: _PositionTransport.liveBatch,
        receivedAt: batch.receivedAt,
        maximumEntries: maximumRecentWireIdentitiesPerDevice,
      );
      if (!repeatedAcrossTransport) {
        novel.add(sample);
      }
    }

    if (novel.isEmpty) {
      return null;
    }
    return EixamDevicePositionBatch(
      samples: novel,
      receivedAt: batch.receivedAt,
      source: batch.source,
      delivery: batch.delivery,
      deviceIdentity: _deviceIdentity(event),
    );
  }

  EixamDevicePositionBatch? _normalizeClassicTel(BleIncomingEvent event) {
    final packet = event.telPacket!;
    final state = _stateFor(event, packet.nodeId);
    final recordIdentity =
        EixamPositionSampleIdentity.classicTel(packet.rawBytes);
    final previouslySeenAt = state.recordIdentities[recordIdentity];
    if (previouslySeenAt != null &&
        event.receivedAt.difference(previouslySeenAt).abs() <=
            crossTransportWindow) {
      return null;
    }

    final wireFingerprint =
        EixamPositionSampleIdentity.telWireFingerprint(packet.rawBytes);
    final repeatedAcrossTransport = state.wasRecentlySeenFromOtherTransport(
      wireFingerprint,
      transport: _PositionTransport.classicTel,
      receivedAt: event.receivedAt,
      window: crossTransportWindow,
    );
    state.rememberRecordIdentity(
      recordIdentity,
      maximumRecordIdentitiesPerDevice,
      receivedAt: event.receivedAt,
    );
    state.rememberWire(
      wireFingerprint,
      transport: _PositionTransport.classicTel,
      receivedAt: event.receivedAt,
      maximumEntries: maximumRecentWireIdentitiesPerDevice,
    );
    if (repeatedAcrossTransport) {
      return null;
    }

    return EixamDevicePositionBatch(
      samples: <EixamDevicePositionSample>[
        EixamDevicePositionSample(
          latitude: packet.position.latitude,
          longitude: packet.position.longitude,
          altitudeMeters: packet.position.altitudeMeters.toDouble(),
          sampledAt: null,
          packetId: packet.packetId,
          source: SdkLocationSource.connectedDevice,
          stableSampleKey: recordIdentity,
        ),
      ],
      receivedAt: event.receivedAt.toUtc(),
      source: SdkLocationSource.connectedDevice,
      deviceIdentity: _deviceIdentity(event),
    );
  }

  _DeviceDedupState _stateFor(BleIncomingEvent event, int nodeId) {
    final deviceIdentity = _deviceIdentity(event);
    final key = '$deviceIdentity:$nodeId';
    final existing = _states.remove(key);
    final state = existing ?? _DeviceDedupState();
    _states[key] = state;
    while (_states.length > maximumDevices) {
      _states.remove(_states.keys.first);
    }
    return state;
  }

  String _deviceIdentity(BleIncomingEvent event) =>
      event.canonicalHardwareId?.trim().isNotEmpty == true
          ? event.canonicalHardwareId!.trim()
          : event.deviceId.trim();
}

enum _PositionTransport { classicTel, liveBatch }

class _RecentWireIdentity {
  const _RecentWireIdentity({
    required this.transport,
    required this.receivedAt,
  });

  final _PositionTransport transport;
  final DateTime receivedAt;
}

class _DeviceDedupState {
  final LinkedHashMap<String, DateTime> recordIdentities =
      LinkedHashMap<String, DateTime>();
  final LinkedHashMap<String, _RecentWireIdentity> recentWireIdentities =
      LinkedHashMap<String, _RecentWireIdentity>();

  bool wasRecentlySeenFromOtherTransport(
    String identity, {
    required _PositionTransport transport,
    required DateTime receivedAt,
    required Duration window,
  }) {
    final previous = recentWireIdentities[identity];
    return previous != null &&
        previous.transport != transport &&
        receivedAt.difference(previous.receivedAt).abs() <= window;
  }

  void rememberRecordIdentity(
    String identity,
    int maximumEntries, {
    DateTime? receivedAt,
  }) {
    recordIdentities.remove(identity);
    recordIdentities[identity] =
        receivedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    while (recordIdentities.length > maximumEntries) {
      recordIdentities.remove(recordIdentities.keys.first);
    }
  }

  void rememberWire(
    String identity, {
    required _PositionTransport transport,
    required DateTime receivedAt,
    required int maximumEntries,
  }) {
    recentWireIdentities.remove(identity);
    recentWireIdentities[identity] = _RecentWireIdentity(
      transport: transport,
      receivedAt: receivedAt,
    );
    while (recentWireIdentities.length > maximumEntries) {
      recentWireIdentities.remove(recentWireIdentities.keys.first);
    }
  }
}
