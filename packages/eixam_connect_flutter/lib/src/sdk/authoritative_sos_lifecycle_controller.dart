import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../storage/secure_store_operation_diagnostics.dart';
import 'authoritative_sos_cadence.dart';
import 'sos_location_ownership_effect.dart';
import 'sos_location_ownership_orchestrator.dart';
import 'sos_location_trace.dart';

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
    SosLocationOwnershipEffectMode locationOwnershipEffectMode =
        SosLocationOwnershipEffectMode.disabled,
  })  : _secureStore = secureStore,
        _clock = clock ?? DateTime.now,
        _locationOwnershipOrchestrator =
            locationOwnershipOrchestrator ?? SosLocationOwnershipOrchestrator(),
        _locationOwnershipEffectDispatcher =
            SosLocationOwnershipEffectDispatcher(
          sink: locationOwnershipEffectSink,
          effectMode: locationOwnershipEffectMode,
        ),
        _current = SosLifecycleSnapshot.idle((clock ?? DateTime.now)().toUtc());

  final SecureKeyValueStore _secureStore;
  final DateTime Function() _clock;
  final SosLocationOwnershipOrchestrator _locationOwnershipOrchestrator;
  final SosLocationOwnershipEffectDispatcher _locationOwnershipEffectDispatcher;
  final StreamController<SosLifecycleSnapshot> _controller =
      StreamController<SosLifecycleSnapshot>.broadcast();
  final StreamController<AuthoritativeSosCadence> _cadenceController =
      StreamController<AuthoritativeSosCadence>.broadcast(sync: true);
  SosLifecycleSnapshot _current;
  SosLifecycleSnapshot? _terminalWatermark;
  String? _ownerScope;
  int _generation = 0;
  int _revision = 0;
  bool _hasCompletedRestoration = false;
  String? _lastRestoredOwnerScope;
  bool _disposed = false;

  SosLifecycleSnapshot get current => _current;
  Stream<SosLifecycleSnapshot> get stream => _controller.stream;

  /// The last authenticated terminal lifecycle for the current account.
  ///
  /// This is a lifecycle fence, not a timing heuristic. It remains valid until
  /// account data is detached/deleted; a newer generation can proceed without
  /// weakening the fence for stale callbacks that still target this one.
  SosLifecycleSnapshot? get activeTerminalWatermark => _terminalWatermark;

  bool get hasActiveTerminalWatermark => activeTerminalWatermark != null;
  AuthoritativeSosCadence get currentCadence => AuthoritativeSosCadence(
        lifecycleRevision: _current.revision,
        lifecycleStage: _current.stage,
        desiredLocalSosOwnership:
            _locationOwnershipOrchestrator.desiredSosOwnership,
      );
  Stream<AuthoritativeSosCadence> get cadenceStream =>
      _cadenceController.stream;
  SosLocationOwnershipOrchestrator get locationOwnershipOrchestrator =>
      _locationOwnershipOrchestrator;
  SosLocationOwnershipEffectDispatcher get locationOwnershipEffectDispatcher =>
      _locationOwnershipEffectDispatcher;

  static String ownerScopeFor(EixamSession session) => sha256
      .convert(utf8.encode('${session.appId}:${session.externalUserId}'))
      .toString();

  Future<SosLifecycleSnapshot> restoreFor(
    EixamSession? session, {
    bool emitToStream = true,
  }) async {
    final ownerScope = session == null ? null : ownerScopeFor(session);
    if (_hasCompletedRestoration && _lastRestoredOwnerScope == ownerScope) {
      _traceIgnoredRestoration(
        reason: 'duplicate_restoration',
        incomingStage: 'not_loaded',
        incomingGenerationPresent: false,
      );
      return _current;
    }
    final revisionAtStart = _revision;
    final priorOwnerScope = _ownerScope;
    final replacingDifferentAccount = priorOwnerScope != null &&
        ownerScope != null &&
        priorOwnerScope != ownerScope;
    _ownerScope = ownerScope;

    if (session == null) {
      return _acceptRestoration(
        SosLifecycleSnapshot.idle(_now()),
        ownerScope: ownerScope,
        revisionAtStart: revisionAtStart,
        replacingDifferentAccount: replacingDifferentAccount,
        emitToStream: emitToStream,
      );
    }
    final encoded = await _readProvenance();
    if (encoded == null || encoded.trim().isEmpty) {
      return _acceptRestoration(
        SosLifecycleSnapshot.idle(_now()),
        ownerScope: ownerScope,
        revisionAtStart: revisionAtStart,
        replacingDifferentAccount: replacingDifferentAccount,
        emitToStream: emitToStream,
      );
    }
    try {
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      if (json['ownerScope'] != ownerScope) {
        // Preserve the other account's record without exposing or adopting it.
        return _acceptRestoration(
          SosLifecycleSnapshot.idle(_now()),
          ownerScope: ownerScope,
          revisionAtStart: revisionAtStart,
          replacingDifferentAccount: replacingDifferentAccount,
          emitToStream: emitToStream,
        );
      }
      final restored = _decode(json);
      if (restored.isTerminal) {
        return _acceptRestoration(
          restored.copyWith(
            localActionable: false,
            externalOnly: false,
            recoveryStatus: SosRecoveryStatus.none,
          ),
          ownerScope: ownerScope,
          revisionAtStart: revisionAtStart,
          replacingDifferentAccount: replacingDifferentAccount,
          emitToStream: emitToStream,
        );
      }
      final recoveryStage = restored.stage == SosLifecycleStage.cancelling
          ? SosLifecycleStage.cancelling
          : SosLifecycleStage.recoveryRequired;
      return _acceptRestoration(
        restored.copyWith(
          stage: recoveryStage,
          localActionable: true,
          externalOnly: false,
          displaySurface: SosDisplaySurface.activeAndHistory,
          recoveryStatus: SosRecoveryStatus.reconciling,
          lastAuthoritativeObservation: _now(),
        ),
        ownerScope: ownerScope,
        revisionAtStart: revisionAtStart,
        replacingDifferentAccount: replacingDifferentAccount,
        emitToStream: emitToStream,
      );
    } catch (_) {
      // An unreadable record is quarantined by retaining it and refusing to
      // infer cancellation or ownership.
      return _acceptRestoration(
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
        ownerScope: ownerScope,
        revisionAtStart: revisionAtStart,
        replacingDifferentAccount: replacingDifferentAccount,
        emitToStream: emitToStream,
      );
    }
  }

  Future<SosLifecycleSnapshot> _acceptRestoration(
    SosLifecycleSnapshot incoming, {
    required String? ownerScope,
    required int revisionAtStart,
    required bool replacingDifferentAccount,
    required bool emitToStream,
  }) {
    if (_hasCompletedRestoration && _lastRestoredOwnerScope == ownerScope) {
      _traceIgnoredRestoration(
        reason: 'duplicate_restoration',
        incomingStage: incoming.stage.name,
        incomingGenerationPresent: incoming.generation > 0,
      );
      return Future<SosLifecycleSnapshot>.value(_current);
    }

    final current = _current;
    final newerLocalLifecycle = current.localActionable &&
        !current.externalOnly &&
        current.isOpen &&
        !replacingDifferentAccount;
    if (newerLocalLifecycle) {
      _hasCompletedRestoration = true;
      _lastRestoredOwnerScope = ownerScope;
      _traceIgnoredRestoration(
        reason: current.revision > revisionAtStart
            ? 'late_restoration'
            : 'restoration_after_local_lifecycle',
        incomingStage: incoming.stage.name,
        incomingGenerationPresent: incoming.generation > 0,
      );
      return Future<SosLifecycleSnapshot>.value(current);
    }

    _hasCompletedRestoration = true;
    _lastRestoredOwnerScope = ownerScope;
    if (incoming.isTerminal) {
      _terminalWatermark = incoming;
    } else if (replacingDifferentAccount || ownerScope == null) {
      _terminalWatermark = null;
    }
    _generation = incoming.generation;
    return _publish(
      incoming,
      persist: false,
      emitToStream: emitToStream,
      reconciliationReason: SosLocationOwnershipReconciliationReason
          .initializationAfterLifecycleRestoration,
    );
  }

  void _traceIgnoredRestoration({
    required String reason,
    required String incomingStage,
    required bool incomingGenerationPresent,
  }) {
    SosLocationTrace.emit('lifecycle_snapshot_ignored', {
      'reason': reason,
      'current_stage': _current.stage.name,
      'incoming_stage': incomingStage,
      'current_local_actionable': _current.localActionable,
      'current_generation_present': _current.generation > 0,
      'incoming_generation_present': incomingGenerationPresent,
    });
  }

  Future<SosLifecycleSnapshot> beginArming({
    required SosLifecycleOrigin origin,
    String? lifecycleId,
    String? triggerSource,
    String? deviceId,
    int? nodeId,
    String? hardwareId,
    bool startNewGenerationAfterTerminal = false,
    bool emitToStream = true,
  }) async {
    final terminalFence = _terminalWatermark;
    final replacingFencedGeneration = terminalFence != null &&
        _current.generation <= terminalFence.generation;
    if (replacingFencedGeneration) {
      if (!startNewGenerationAfterTerminal) {
        return _rejectFencedOpenTransition(
          source: 'begin_arming',
          candidateStage: SosLifecycleStage.arming,
        );
      }
      _generation = terminalFence.generation;
    }
    if (_current.isOpen && !replacingFencedGeneration) {
      return _current;
    }
    _generation += 1;
    final now = _now();
    final identity = nodeId?.toString() ?? deviceId ?? 'local';
    final requestedLifecycleId = lifecycleId;
    final effectiveLifecycleId = replacingFencedGeneration &&
            requestedLifecycleId != null &&
            requestedLifecycleId == terminalFence.lifecycleId
        ? '$requestedLifecycleId:g$_generation'
        : requestedLifecycleId;
    return _publish(
      SosLifecycleSnapshot(
        stage: SosLifecycleStage.arming,
        lifecycleId: effectiveLifecycleId ??
            'sos:$identity:${now.microsecondsSinceEpoch}:$_generation',
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
      emitToStream: emitToStream,
    );
  }

  Future<SosLifecycleSnapshot> beginActivating({
    required SosLifecycleOrigin origin,
    String? triggerSource,
    String? deviceId,
    int? nodeId,
    String? hardwareId,
    bool startNewGenerationAfterTerminal = false,
  }) async {
    if (!_current.isOpen ||
        _current.isTerminal ||
        _terminalFenceRejectsLifecycleCandidate(_current)) {
      final arming = await beginArming(
        origin: origin,
        triggerSource: triggerSource,
        deviceId: deviceId,
        nodeId: nodeId,
        hardwareId: hardwareId,
        startNewGenerationAfterTerminal: startNewGenerationAfterTerminal,
      );
      if (arming.stage != SosLifecycleStage.arming) {
        return arming;
      }
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
    if (_current.isTerminal ||
        _terminalFenceRejectsLifecycleCandidate(_current)) {
      return _rejectFencedOpenTransition(
        source: 'confirm_active',
        candidateStage: SosLifecycleStage.active,
      );
    }
    if (_current.lifecycleId.isEmpty) {
      await beginActivating(
        origin: origin,
        triggerSource: triggerSource,
        deviceId: deviceId,
        nodeId: nodeId,
        hardwareId: hardwareId,
      );
    }
    final current = _current;
    final confirmedCanonicalIncident = _confirmedCanonicalIncident(current);
    final preserveConfirmedCanonical = confirmedCanonicalIncident != null;
    final incomingRefreshesConfirmedCanonical = preserveConfirmedCanonical &&
        incident?.isBackendConfirmed == true &&
        incident?.id == confirmedCanonicalIncident.id;
    return _publish(
      current.copyWith(
        stage: SosLifecycleStage.active,
        // Once this generation owns a confirmed canonical Backend incident,
        // later ACTIVE evidence can enrich it but cannot replace its ownership
        // or identity with a stale provisional/device projection.
        origin: preserveConfirmedCanonical ? current.origin : origin,
        localActionable: true,
        externalOnly: false,
        displaySurface: SosDisplaySurface.activeAndHistory,
        localIncidentId: preserveConfirmedCanonical
            ? current.localIncidentId ?? localIncidentId
            : localIncidentId,
        backendIncidentId: preserveConfirmedCanonical
            ? current.backendIncidentId
            : backendIncidentId,
        triggerSource: preserveConfirmedCanonical
            ? current.triggerSource ?? triggerSource
            : triggerSource,
        deviceId: preserveConfirmedCanonical
            ? current.deviceId ?? deviceId
            : deviceId,
        nodeId: preserveConfirmedCanonical ? current.nodeId ?? nodeId : nodeId,
        hardwareId: preserveConfirmedCanonical
            ? current.hardwareId ?? hardwareId
            : hardwareId,
        activationTimestamp: current.activationTimestamp ?? _now(),
        cancellationPhase: SosCancellationPhase.none,
        recoveryStatus: recoveryStatus,
        failureCode: null,
        incident:
            preserveConfirmedCanonical && !incomingRefreshesConfirmedCanonical
                ? confirmedCanonicalIncident
                : incident,
        lastAuthoritativeObservation: _now(),
      ),
    );
  }

  SosIncident? _confirmedCanonicalIncident(SosLifecycleSnapshot lifecycle) {
    if (!lifecycle.isOpen) {
      return null;
    }
    final backendIncidentId = lifecycle.backendIncidentId?.trim();
    final incident = lifecycle.incident;
    if (backendIncidentId == null ||
        backendIncidentId.isEmpty ||
        incident == null ||
        !incident.isBackendConfirmed ||
        incident.id != backendIncidentId) {
      return null;
    }
    return incident;
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
    String? deviceCycleKey,
    bool emitToStream = true,
  }) async {
    assert(
      stage == SosLifecycleStage.cancelled ||
          stage == SosLifecycleStage.resolved,
    );
    final terminal = _current.copyWith(
      stage: stage,
      localActionable: false,
      displaySurface: SosDisplaySurface.historyOnly,
      cancellationPhase: stage == SosLifecycleStage.cancelled
          ? SosCancellationPhase.fullyResolved
          : _current.cancellationPhase,
      recoveryStatus: SosRecoveryStatus.none,
      failureCode: null,
      localIncidentId: _current.localIncidentId ??
          incident?.provisionalIncidentId ??
          (incident?.isBackendConfirmed == false ? incident?.id : null),
      backendIncidentId: _current.backendIncidentId ??
          (incident?.isBackendConfirmed == true ? incident?.id : null),
      deviceId: _current.deviceId ?? incident?.deviceId,
      nodeId: _current.nodeId ?? incident?.originatorNodeId,
      hardwareId: _current.hardwareId ?? incident?.hardwareId,
      deviceCycleKey: deviceCycleKey ?? _current.deviceCycleKey,
      triggerSource: _current.triggerSource ?? incident?.triggerSource,
      activationTimestamp:
          _current.activationTimestamp ?? incident?.createdAt.toUtc(),
      incident: incident,
      lastAuthoritativeObservation: _now(),
    );
    final ownerScope = _ownerScope;
    // Establish precedence before durable I/O yields. Live BLE packets can be
    // evaluated while the secure write is pending, and must already see the
    // accepted terminal candidate.
    _terminalWatermark = terminal;
    try {
      if (ownerScope != null) {
        await _writeProvenance(terminal, ownerScope);
      }
    } catch (_) {
      // Durable storage failure is observable to the caller, but cannot revoke
      // authenticated Backend terminal truth in this process.
      await _publish(
        terminal,
        persist: false,
        emitToStream: emitToStream,
      );
      rethrow;
    }
    return _publish(
      terminal,
      persist: false,
      emitToStream: emitToStream,
    );
  }

  Future<void> detachAccount() async {
    _ownerScope = null;
    _hasCompletedRestoration = false;
    _lastRestoredOwnerScope = null;
    _terminalWatermark = null;
    await _publish(SosLifecycleSnapshot.idle(_now()), persist: false);
  }

  Future<void> deleteAccountData() async {
    await _deleteProvenance();
    await detachAccount();
  }

  Future<String?> _readProvenance() async {
    try {
      return await _secureStore.read(
        SecureStorageKeys.sdkSosLifecycleProvenance.value,
      );
    } on SecureKeyValueStoreException catch (error) {
      reportSecureStoreOperationFailure(
        SecureStoreOperation.sosLifecycleRead,
        error,
      );
      rethrow;
    }
  }

  Future<void> _deleteProvenance() async {
    try {
      await _secureStore.delete(
        SecureStorageKeys.sdkSosLifecycleProvenance.value,
      );
    } on SecureKeyValueStoreException catch (error) {
      reportSecureStoreOperationFailure(
        SecureStoreOperation.sosLifecycleDelete,
        error,
      );
      rethrow;
    }
  }

  Future<void> _writeProvenance(
    SosLifecycleSnapshot snapshot,
    String ownerScope,
  ) async {
    try {
      await _secureStore.write(
        SecureStorageKeys.sdkSosLifecycleProvenance.value,
        jsonEncode(_encode(snapshot, ownerScope)),
      );
    } on SecureKeyValueStoreException catch (error) {
      reportSecureStoreOperationFailure(
        SecureStoreOperation.sosLifecycleWrite,
        error,
      );
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final ownership = _locationOwnershipOrchestrator.shadowState;
    final effects = _locationOwnershipEffectDispatcher.diagnostics;
    SosLocationTrace.emit('lifecycle_dispose_begin', {
      'desired': ownership.desiredSosOwnership,
      'activate_count': ownership.activateTransitionCount,
      'deactivate_count': ownership.deactivateTransitionCount,
      'emitted_effects': effects.emittedCommandCount,
      'completed_effects': effects.completedCommandCount,
      'effect_failures': effects.failureCount,
    });
    _locationOwnershipOrchestrator.dispose();
    await _locationOwnershipEffectDispatcher.dispose();
    await _cadenceController.close();
    await _controller.close();
    SosLocationTrace.emit('lifecycle_dispose_done', {
      'desired': false,
      'pending_effects': 0,
      'effect_tail_drained': true,
    });
  }

  Future<void> reconcileLocationOwnershipForTesting() async {
    return reconcileLocationOwnership(
      SosLocationOwnershipReconciliationReason.explicitInternalTestTrigger,
    );
  }

  Future<void> reconcileLocationOwnership(
    SosLocationOwnershipReconciliationReason reason,
  ) async {
    if (_disposed) {
      return;
    }
    _locationOwnershipEffectDispatcher.reconcile(
      _locationOwnershipOrchestrator.desiredSosOwnership,
      reason,
    );
    await _locationOwnershipEffectDispatcher.whenIdle;
  }

  void publishCurrent() {
    if (!_disposed && !_controller.isClosed) {
      _controller.add(_current);
    }
  }

  Future<SosLifecycleSnapshot> _publish(
    SosLifecycleSnapshot next, {
    bool persist = true,
    bool emitToStream = true,
    SosLocationOwnershipReconciliationReason reconciliationReason =
        SosLocationOwnershipReconciliationReason
            .newerAuthoritativeLifecycleRevision,
  }) async {
    if (_terminalFenceRejectsLifecycleCandidate(next)) {
      return _rejectFencedOpenTransition(
        source: 'publish',
        candidateStage: next.stage,
      );
    }
    if (next.isTerminal && _current.generation > next.generation) {
      SosLocationTrace.emit('lifecycle_snapshot_ignored', {
        'reason': 'stale_terminal_older_generation',
        'current_generation': _current.generation,
        'incoming_generation': next.generation,
        'incoming_stage': next.stage.name,
      });
      return _current;
    }
    _revision += 1;
    _current = next.copyWith(revision: _revision);
    next = _current;
    if (!_disposed) {
      final transition = _locationOwnershipOrchestrator.accept(next);
      final effect = sosLocationOwnershipEffectFor(transition);
      final shadow = _locationOwnershipOrchestrator.shadowState;
      SosLocationTrace.emit('lifecycle_decision', {
        'revision': next.revision,
        'generation': next.generation,
        'stage': next.stage.name,
        'origin': next.origin.name,
        'local_actionable': next.localActionable,
        'external_only': next.externalOnly,
        'directive': shadow.lastDirective?.name,
        'transition': transition.name,
        'desired': shadow.desiredSosOwnership,
        'activate_count': shadow.activateTransitionCount,
        'deactivate_count': shadow.deactivateTransitionCount,
        'reconciliation_reason': reconciliationReason.name,
      });
      if (!_cadenceController.isClosed) {
        _cadenceController.add(
          AuthoritativeSosCadence(
            lifecycleRevision: next.revision,
            lifecycleStage: next.stage,
            desiredLocalSosOwnership: shadow.desiredSosOwnership,
          ),
        );
      }
      if (effect != null) {
        _locationOwnershipEffectDispatcher.offer(effect);
      }
      _locationOwnershipEffectDispatcher.reconcile(
        _locationOwnershipOrchestrator.desiredSosOwnership,
        reconciliationReason,
      );
    }
    final shouldPersistOpen = next.isOpen && next.localIncidentId != null;
    if (persist &&
        (shouldPersistOpen || next.isTerminal) &&
        _ownerScope != null) {
      await _writeProvenance(next, _ownerScope!);
    }
    if (emitToStream && !_controller.isClosed) {
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
        'deviceCycleKey': value.deviceCycleKey,
        'triggerSource': value.triggerSource,
        'activationTimestamp': value.activationTimestamp?.toIso8601String(),
        'lastObservation': value.lastAuthoritativeObservation.toIso8601String(),
        'cancellationPhase': value.cancellationPhase.name,
        if (value.isTerminal)
          'terminalTimestamp':
              value.lastAuthoritativeObservation.toUtc().toIso8601String(),
      };

  bool _terminalFenceRejectsLifecycleCandidate(
    SosLifecycleSnapshot candidate,
  ) {
    final terminalFence = _terminalWatermark;
    if (terminalFence == null ||
        candidate.isTerminal ||
        candidate.stage == SosLifecycleStage.idle) {
      return false;
    }
    return candidate.generation <= terminalFence.generation ||
        candidate.lifecycleId == terminalFence.lifecycleId;
  }

  SosLifecycleSnapshot _rejectFencedOpenTransition({
    required String source,
    required SosLifecycleStage candidateStage,
  }) {
    final terminalFence = _terminalWatermark;
    if (terminalFence == null) {
      return _current;
    }
    SosLocationTrace.emit('lifecycle_snapshot_ignored', {
      'reason': 'authoritative_backend_terminal_fence',
      'source': source,
      'candidate_stage': candidateStage.name,
      'fenced_stage': terminalFence.stage.name,
      'fenced_generation': terminalFence.generation,
    });
    return terminalFence;
  }

  SosLifecycleSnapshot _decode(Map<String, dynamic> json) {
    T enumValue<T extends Enum>(List<T> values, String? name, T fallback) =>
        values.where((value) => value.name == name).firstOrNull ?? fallback;
    final activationTimestamp = DateTime.tryParse(
      json['activationTimestamp'] as String? ?? '',
    );
    final stage = enumValue(
      SosLifecycleStage.values,
      json['stage'] as String?,
      SosLifecycleStage.recoveryRequired,
    );
    return SosLifecycleSnapshot(
      stage: stage,
      lifecycleId: json['lifecycleId'] as String,
      generation: json['generation'] as int? ?? 0,
      origin: enumValue(
        SosLifecycleOrigin.values,
        json['origin'] as String?,
        SosLifecycleOrigin.unknown,
      ),
      localActionable: true,
      externalOnly: false,
      displaySurface: stage == SosLifecycleStage.cancelled ||
              stage == SosLifecycleStage.resolved
          ? SosDisplaySurface.historyOnly
          : SosDisplaySurface.activeAndHistory,
      localIncidentId: json['localIncidentId'] as String?,
      backendIncidentId: json['backendIncidentId'] as String?,
      deviceId: json['deviceId'] as String?,
      nodeId: json['nodeId'] as int?,
      hardwareId: json['hardwareId'] as String?,
      deviceCycleKey: json['deviceCycleKey'] as String?,
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
