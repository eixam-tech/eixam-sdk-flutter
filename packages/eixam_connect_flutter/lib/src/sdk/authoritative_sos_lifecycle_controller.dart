import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'sos_location_ownership_effect.dart';
import 'sos_location_ownership_orchestrator.dart';

/// Owns SOS generation, account-scoped provenance and terminal cleanup.
///
/// This controller deliberately persists metadata only. Incident payloads,
/// positions, contacts, credentials and raw transport data never enter the
/// secure record.
final class AuthoritativeSosLifecycleController {
  AuthoritativeSosLifecycleController({
    required SecureKeyValueStore secureStore,
    DateTime Function()? clock,
    SosLocationOwnershipOrchestrator? locationOwnershipOrchestrator,
    SosLocationOwnershipEffectSink locationOwnershipEffectSink =
        const NoopSosLocationOwnershipEffectSink(),
  })  : _secureStore = secureStore,
        _clock = clock ?? DateTime.now,
        _locationOwnershipOrchestrator =
            locationOwnershipOrchestrator ?? SosLocationOwnershipOrchestrator(),
        _locationOwnershipEffectDispatcher =
            SosLocationOwnershipEffectDispatcher(
          sink: locationOwnershipEffectSink,
        ),
        _current = SosLifecycleSnapshot.idle((clock ?? DateTime.now)().toUtc());

  final SecureKeyValueStore _secureStore;
  final DateTime Function() _clock;
  final SosLocationOwnershipOrchestrator _locationOwnershipOrchestrator;
  final SosLocationOwnershipEffectDispatcher _locationOwnershipEffectDispatcher;
  final StreamController<SosLifecycleSnapshot> _controller =
      StreamController<SosLifecycleSnapshot>.broadcast();
  SosLifecycleSnapshot _current;
  String? _ownerScope;
  int _generation = 0;
  int _revision = 0;
  bool _disposed = false;

  SosLifecycleSnapshot get current => _current;
  Stream<SosLifecycleSnapshot> get stream => _controller.stream;
  SosLocationOwnershipOrchestrator get locationOwnershipOrchestrator =>
      _locationOwnershipOrchestrator;
  SosLocationOwnershipEffectDispatcher get locationOwnershipEffectDispatcher =>
      _locationOwnershipEffectDispatcher;

  static String ownerScopeFor(EixamSession session) => sha256
      .convert(utf8.encode('${session.appId}:${session.externalUserId}'))
      .toString();

  Future<SosLifecycleSnapshot> restoreFor(EixamSession? session) async {
    if (session == null) {
      _ownerScope = null;
      return _publish(SosLifecycleSnapshot.idle(_now()), persist: false);
    }
    final ownerScope = ownerScopeFor(session);
    _ownerScope = ownerScope;
    final encoded = await _secureStore.read(
      SecureStorageKeys.sdkSosLifecycleProvenance.value,
    );
    if (encoded == null || encoded.trim().isEmpty) {
      return _publish(SosLifecycleSnapshot.idle(_now()), persist: false);
    }
    try {
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      if (json['ownerScope'] != ownerScope) {
        // Preserve the other account's record without exposing or adopting it.
        return _publish(SosLifecycleSnapshot.idle(_now()), persist: false);
      }
      final restored = _decode(json);
      _generation = restored.generation;
      final recoveryStage = restored.stage == SosLifecycleStage.cancelling
          ? SosLifecycleStage.cancelling
          : SosLifecycleStage.recoveryRequired;
      return _publish(
        restored.copyWith(
          stage: recoveryStage,
          localActionable: true,
          externalOnly: false,
          displaySurface: SosDisplaySurface.activeAndHistory,
          recoveryStatus: SosRecoveryStatus.reconciling,
          lastAuthoritativeObservation: _now(),
        ),
      );
    } catch (_) {
      // An unreadable record is quarantined by retaining it and refusing to
      // infer cancellation or ownership.
      return _publish(
        SosLifecycleSnapshot(
          stage: SosLifecycleStage.recoveryRequired,
          lifecycleId: 'sos-recovery:${_now().microsecondsSinceEpoch}',
          generation: 0,
          origin: SosLifecycleOrigin.unknown,
          localActionable: false,
          externalOnly: false,
          displaySurface: SosDisplaySurface.activeAndHistory,
          lastAuthoritativeObservation: _now(),
          recoveryStatus: SosRecoveryStatus.unresolved,
          failureCode: 'E_SOS_PROVENANCE_UNREADABLE',
        ),
        persist: false,
      );
    }
  }

  Future<SosLifecycleSnapshot> beginArming({
    required SosLifecycleOrigin origin,
    String? triggerSource,
    String? deviceId,
    int? nodeId,
    String? hardwareId,
  }) async {
    if (_current.isOpen) {
      return _current;
    }
    _generation += 1;
    final now = _now();
    final identity = nodeId?.toString() ?? deviceId ?? 'local';
    return _publish(
      SosLifecycleSnapshot(
        stage: SosLifecycleStage.arming,
        lifecycleId: 'sos:$identity:${now.microsecondsSinceEpoch}:$_generation',
        generation: _generation,
        origin: origin,
        localActionable: true,
        externalOnly: false,
        displaySurface: SosDisplaySurface.activeAndHistory,
        deviceId: deviceId,
        nodeId: nodeId,
        hardwareId: hardwareId,
        triggerSource: triggerSource,
        lastAuthoritativeObservation: now,
      ),
      // Arming alone is not proof of an active locally-owned SOS.
      persist: false,
    );
  }

  Future<SosLifecycleSnapshot> beginActivating({
    required SosLifecycleOrigin origin,
    String? triggerSource,
    String? deviceId,
    int? nodeId,
    String? hardwareId,
  }) async {
    if (!_current.isOpen || _current.isTerminal) {
      await beginArming(
        origin: origin,
        triggerSource: triggerSource,
        deviceId: deviceId,
        nodeId: nodeId,
        hardwareId: hardwareId,
      );
    }
    return _publish(
      _current.copyWith(
        stage: SosLifecycleStage.activating,
        origin: origin,
        triggerSource: triggerSource,
        deviceId: deviceId,
        nodeId: nodeId,
        hardwareId: hardwareId,
        recoveryStatus: SosRecoveryStatus.none,
        failureCode: null,
        lastAuthoritativeObservation: _now(),
      ),
      persist: false,
    );
  }

  Future<SosLifecycleSnapshot> confirmActive({
    required SosLifecycleOrigin origin,
    required String localIncidentId,
    String? backendIncidentId,
    String? triggerSource,
    String? deviceId,
    int? nodeId,
    String? hardwareId,
    SosIncident? incident,
    SosRecoveryStatus recoveryStatus = SosRecoveryStatus.none,
  }) async {
    if (_current.lifecycleId.isEmpty || _current.isTerminal) {
      await beginActivating(
        origin: origin,
        triggerSource: triggerSource,
        deviceId: deviceId,
        nodeId: nodeId,
        hardwareId: hardwareId,
      );
    }
    return _publish(
      _current.copyWith(
        stage: SosLifecycleStage.active,
        origin: origin,
        localActionable: true,
        externalOnly: false,
        displaySurface: SosDisplaySurface.activeAndHistory,
        localIncidentId: localIncidentId,
        backendIncidentId: backendIncidentId,
        triggerSource: triggerSource,
        deviceId: deviceId,
        nodeId: nodeId,
        hardwareId: hardwareId,
        activationTimestamp: _current.activationTimestamp ?? _now(),
        cancellationPhase: SosCancellationPhase.none,
        recoveryStatus: recoveryStatus,
        failureCode: null,
        incident: incident,
        lastAuthoritativeObservation: _now(),
      ),
    );
  }

  Future<SosLifecycleSnapshot> requireRecovery(
    String code, {
    bool preserveLocalOwnership = true,
    String? backendIncidentId,
    SosIncident? incident,
  }) =>
      _publish(
        _current.copyWith(
          stage: SosLifecycleStage.recoveryRequired,
          localActionable:
              preserveLocalOwnership && _current.localIncidentId != null,
          recoveryStatus: SosRecoveryStatus.unresolved,
          failureCode: code,
          backendIncidentId: backendIncidentId,
          incident: incident,
          lastAuthoritativeObservation: _now(),
        ),
      );

  Future<SosLifecycleSnapshot> activationFailed(String code) => _publish(
        _current.copyWith(
          stage: SosLifecycleStage.activationFailed,
          failureCode: code,
          lastAuthoritativeObservation: _now(),
        ),
        persist: false,
      );

  Future<SosLifecycleSnapshot> beginCancellation() => _publish(
        _current.copyWith(
          stage: SosLifecycleStage.cancelling,
          cancellationPhase: SosCancellationPhase.requested,
          failureCode: null,
          lastAuthoritativeObservation: _now(),
        ),
      );

  Future<SosLifecycleSnapshot> cancellationAccepted({
    required bool backendConfirmed,
    required bool deviceConfirmed,
  }) =>
      _publish(
        _current.copyWith(
          stage: SosLifecycleStage.cancelling,
          cancellationPhase: backendConfirmed && deviceConfirmed
              ? SosCancellationPhase.fullyResolved
              : backendConfirmed
                  ? SosCancellationPhase.backendConfirmed
                  : deviceConfirmed
                      ? SosCancellationPhase.deviceConfirmed
                      : SosCancellationPhase.transportAccepted,
          lastAuthoritativeObservation: _now(),
        ),
      );

  Future<SosLifecycleSnapshot> cancellationFailed(String code) => _publish(
        _current.copyWith(
          stage: SosLifecycleStage.cancellationFailed,
          cancellationPhase: SosCancellationPhase.failed,
          failureCode: code,
          localActionable: true,
          externalOnly: false,
          lastAuthoritativeObservation: _now(),
        ),
      );

  Future<SosLifecycleSnapshot> confirmTerminal({
    required SosLifecycleStage stage,
    SosIncident? incident,
  }) async {
    assert(
      stage == SosLifecycleStage.cancelled ||
          stage == SosLifecycleStage.resolved,
    );
    final terminal = _current.copyWith(
      stage: stage,
      localActionable: false,
      cancellationPhase: stage == SosLifecycleStage.cancelled
          ? SosCancellationPhase.fullyResolved
          : _current.cancellationPhase,
      recoveryStatus: SosRecoveryStatus.none,
      failureCode: null,
      incident: incident,
      lastAuthoritativeObservation: _now(),
    );
    await _secureStore.delete(
      SecureStorageKeys.sdkSosLifecycleProvenance.value,
    );
    return _publish(terminal, persist: false);
  }

  Future<void> detachAccount() async {
    _ownerScope = null;
    await _publish(SosLifecycleSnapshot.idle(_now()), persist: false);
  }

  Future<void> deleteAccountData() async {
    await _secureStore.delete(
      SecureStorageKeys.sdkSosLifecycleProvenance.value,
    );
    await detachAccount();
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _locationOwnershipOrchestrator.dispose();
    _locationOwnershipEffectDispatcher.dispose();
    await _controller.close();
  }

  Future<SosLifecycleSnapshot> _publish(
    SosLifecycleSnapshot next, {
    bool persist = true,
  }) async {
    _revision += 1;
    _current = next.copyWith(revision: _revision);
    next = _current;
    if (!_disposed) {
      final transition = _locationOwnershipOrchestrator.accept(next);
      final effect = sosLocationOwnershipEffectFor(transition);
      if (effect != null) {
        _locationOwnershipEffectDispatcher.offer(effect);
      }
    }
    if (persist &&
        next.isOpen &&
        next.localIncidentId != null &&
        _ownerScope != null) {
      await _secureStore.write(
        SecureStorageKeys.sdkSosLifecycleProvenance.value,
        jsonEncode(_encode(next, _ownerScope!)),
      );
    }
    if (!_controller.isClosed) {
      _controller.add(next);
    }
    return next;
  }

  Map<String, Object?> _encode(
    SosLifecycleSnapshot value,
    String ownerScope,
  ) =>
      <String, Object?>{
        'version': 1,
        'ownerScope': ownerScope,
        'lifecycleId': value.lifecycleId,
        'generation': value.generation,
        'stage': value.stage.name,
        'origin': value.origin.name,
        'localIncidentId': value.localIncidentId,
        'backendIncidentId': value.backendIncidentId,
        'deviceId': value.deviceId,
        'nodeId': value.nodeId,
        'hardwareId': value.hardwareId,
        'triggerSource': value.triggerSource,
        'activationTimestamp': value.activationTimestamp?.toIso8601String(),
        'lastObservation': value.lastAuthoritativeObservation.toIso8601String(),
        'cancellationPhase': value.cancellationPhase.name,
      };

  SosLifecycleSnapshot _decode(Map<String, dynamic> json) {
    T enumValue<T extends Enum>(List<T> values, String? name, T fallback) =>
        values.where((value) => value.name == name).firstOrNull ?? fallback;
    final activationTimestamp = DateTime.tryParse(
      json['activationTimestamp'] as String? ?? '',
    );
    return SosLifecycleSnapshot(
      stage: enumValue(
        SosLifecycleStage.values,
        json['stage'] as String?,
        SosLifecycleStage.recoveryRequired,
      ),
      lifecycleId: json['lifecycleId'] as String,
      generation: json['generation'] as int? ?? 0,
      origin: enumValue(
        SosLifecycleOrigin.values,
        json['origin'] as String?,
        SosLifecycleOrigin.unknown,
      ),
      localActionable: true,
      externalOnly: false,
      displaySurface: SosDisplaySurface.activeAndHistory,
      localIncidentId: json['localIncidentId'] as String?,
      backendIncidentId: json['backendIncidentId'] as String?,
      deviceId: json['deviceId'] as String?,
      nodeId: json['nodeId'] as int?,
      hardwareId: json['hardwareId'] as String?,
      triggerSource: json['triggerSource'] as String?,
      activationTimestamp: activationTimestamp,
      lastAuthoritativeObservation:
          DateTime.tryParse(json['lastObservation'] as String? ?? '') ?? _now(),
      cancellationPhase: enumValue(
        SosCancellationPhase.values,
        json['cancellationPhase'] as String?,
        SosCancellationPhase.none,
      ),
    );
  }

  DateTime _now() => _clock().toUtc();
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
