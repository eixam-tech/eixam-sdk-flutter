import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/tag_radio_repair_ledger.dart';
import '../data/datasources_local/tag_volume_store.dart';
import '../diagnostics/sdk_release_log.dart';
import '../provisioning/provisioning_command_result.dart';
import '../provisioning/strict_device_provisioning_config.dart';

/// `sos_state` of the `0x23` v3 reply (doc 36 §9, byte 18).
enum TagSosState {
  inactive(0),
  countdown(1),
  active(2),
  acknowledged(3),
  resolved(4);

  const TagSosState(this.wire);
  final int wire;

  /// Countdown, active or acknowledged: the TAG is in an SOS episode.
  bool get isOpen =>
      this == TagSosState.countdown ||
      this == TagSosState.active ||
      this == TagSosState.acknowledged;

  static TagSosState? fromWire(int value) {
    for (final state in values) {
      if (state.wire == value) return state;
    }
    return null;
  }
}

/// What the TAG's own status says about its SOS when the link comes up.
///
/// [TagSosEvidenceReported] maps 1:1 to the `0x23` v3 reply of the SOS
/// episode v2 contract (doc 36 §9: `E9 78 03`, `active_cycle`, `sos_state`,
/// `pending_cycle × n`). The TAG sends it only after `0x0E 02` (§7.1). Every
/// released firmware (up to 2.7.69) answers v2 (`E9 78 02`, 14 B), which has
/// no SOS field, and the SOS characteristic only holds the last frame
/// notified while a phone was connected: [TagSosEvidenceUnavailable], and the
/// stale/new decision stays with native's frame-driven path (F17c). Never
/// inferred.
sealed class TagSessionSosEvidence {
  const TagSessionSosEvidence();

  /// Parses the raw `0x23` reply. Anything but a well-formed v3 reply
  /// (header `E9 78 03`, length `20 + 4·n_pending`, n ≤ 4, known
  /// `sos_state`) is unavailable.
  static TagSessionSosEvidence fromStatusReply(List<int> bytes) {
    if (bytes.length < 20 ||
        bytes[0] != 0xE9 ||
        bytes[1] != 0x78 ||
        bytes[2] != 0x03) {
      return const TagSosEvidenceUnavailable();
    }
    final pendingCount = bytes[19];
    final state = TagSosState.fromWire(bytes[18]);
    if (pendingCount > 4 ||
        bytes.length != 20 + 4 * pendingCount ||
        state == null) {
      return const TagSosEvidenceUnavailable();
    }
    return TagSosEvidenceReported(
      activeCycle: _u32(bytes, 14),
      sosState: state,
      pendingCycles: List<int>.unmodifiable(<int>[
        for (var i = 0; i < pendingCount; i++) _u32(bytes, 20 + 4 * i),
      ]),
    );
  }

  static int _u32(List<int> b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
}

/// Status v2 (today's firmware): the TAG does not report its SOS state.
final class TagSosEvidenceUnavailable extends TagSessionSosEvidence {
  const TagSosEvidenceUnavailable();
}

/// Doc 36 §9 fields, as reported by the TAG.
final class TagSosEvidenceReported extends TagSessionSosEvidence {
  const TagSosEvidenceReported({
    required this.activeCycle,
    required this.sosState,
    required this.pendingCycles,
  });

  /// The active episode's `cycle`; 0 when there is none.
  final int activeCycle;
  final TagSosState sosState;

  /// Pending cancels, oldest first (at most 4).
  final List<int> pendingCycles;
}

/// Doc 36 §7.1: `[0x0E][0x02]` asks the TAG for the v2 BLE contract on this
/// connection; only `E9 7A … OK` activates it. `REJECT`, `OK_NOCHANGE`, a
/// timeout or a lost link leave the connection on v1. Frames that arrive
/// before the OK are v1 frames and are handled as today. Returns the
/// contract version now active (1 or 2).
///
/// Not wired in production yet: v2 replaces the TAG's own SOS frames with
/// `0xE5`/`0xE8`, which the SDK does not parse yet.
Future<int> negotiateTagBleContractV2(
  Future<ProvisioningCommandOutcome> Function(int opcode, List<int> bytes)
  sendAckCommand,
) async {
  try {
    final outcome = await sendAckCommand(0x0E, const <int>[0x0E, 0x02]);
    return outcome == ProvisioningCommandOutcome.ok ? 2 : 1;
  } catch (_) {
    return 1;
  }
}

/// Fixed diagnostic codes. Release-logged as `TAG_SESSION_BOOTSTRAP code=…`.
enum TagSessionBootstrapCode {
  contractNegotiated('contract_negotiated'),
  statusReadFailed('status_read_failed'),
  sosEvidenceUnavailable('sos_evidence_unavailable'),
  sosEvidenceReported('sos_evidence_reported'),
  deferredForSafety('deferred_for_safety'),
  volumeRestored('volume_restored'),
  volumeNotStored('volume_not_stored'),
  volumeWriteFailed('volume_write_failed'),
  volumeStoreReadFailed('volume_store_read_failed'),
  radioOk('radio_ok'),
  radioTxDisabled('radio_tx_disabled'),
  radioAwaitingQuietTag('radio_awaiting_quiet_tag'),
  radioRepairSkipped('radio_repair_skipped'),
  radioRepairStarted('radio_repair_started'),
  radioRepairNotApplied('radio_repair_not_applied'),
  radioRepairWriteFailed('radio_repair_write_failed'),
  radioRepairRebootSkipped('radio_repair_reboot_skipped'),
  radioRepairRebooting('radio_repair_rebooting'),
  radioRepairVerified('radio_repair_verified'),
  radioRepairFailed('radio_repair_failed');

  const TagSessionBootstrapCode(this.wire);
  final String wire;
}

final class TagSessionBootstrapEvent {
  const TagSessionBootstrapEvent(this.code, {this.reason});

  final TagSessionBootstrapCode code;

  /// A fixed word (gate name, step), never an identifier or payload.
  final String? reason;

  @override
  String toString() =>
      'TagSessionBootstrapEvent(${code.wire}${reason == null ? '' : ', $reason'})';
}

/// One bootstrap per TAG connection, in this order:
///
/// 1. [contractHandshake]: the doc 36 §7.1 handshake
///    ([negotiateTagBleContractV2]). Null in production until the SDK
///    parses the v2 frames.
/// 2. One `0x23` read.
/// 3. The TAG's SOS evidence (stale/new) first, for safety. See
///    [TagSessionSosEvidence]: unavailable on today's firmware. A reported
///    open SOS holds steps 4 like an SDK-side SOS, and goes to
///    [onSosEvidence] for the stale/new decision (null today).
/// 4. Only while no SOS, countdown or prompt is open ([sosHold] is null):
///    re-send the stored volume, and check the radio. A radio that is not an
///    Eixam provisioning config is rewritten with exactly the provisioning
///    frames (0x20 full RF, 0x21 SOS RF, 0x22 reboot), at most once per
///    connection, and only after the TAG has been quiet (no SOS frame) for
///    [quietWindow]: status v2 cannot show a ringing TAG, and a reboot must
///    never cut a real SOS. The next connection verifies; still wrong =
///    [TagSessionBootstrapCode.radioRepairFailed] and no more repairs of that
///    TAG in this app session (no retry loop).
final class TagSessionBootstrap {
  TagSessionBootstrap({
    required this.readStatus,
    required this.sosHold,
    required this.radioWriteHold,
    required this.lastSosFrameAt,
    required this.volumeStore,
    required this.sendNotificationVolume,
    required this.sendSosVolume,
    required this.fetchProvisioningConfig,
    required this.sendAckCommand,
    required this.reboot,
    bool Function()? isLinkUp,
    this.contractHandshake,
    this.onSosEvidence,
    TagRadioRepairLedger? repairLedger,
    this.repairBlockCooldown = const Duration(hours: 24),
    TagSessionSosEvidence Function(DeviceRuntimeStatus status)? sosEvidence,
    DateTime Function()? clock,
    Timer Function(Duration delay, void Function() callback)? timer,
    this.quietWindow = defaultQuietWindow,
    this.holdRecheck = defaultHoldRecheck,
  }) : sosEvidence = sosEvidence ?? _evidenceFromStatus,
       _ledger = repairLedger ?? InMemoryTagRadioRepairLedger(),
       _isLinkUp = isLinkUp ?? _alwaysUp,
       _clock = clock ?? DateTime.now,
       _timer = timer ?? Timer.new;

  /// The TAG's longest gap between SOS frames is its 60 s retry (from TX
  /// end). Two gaps plus margin, so one lost BLE notification cannot make a
  /// ringing TAG look quiet.
  static const Duration defaultQuietWindow = Duration(seconds: 150);

  /// While deferred for safety, re-check this often (plus on
  /// [safetyMayHaveCleared]) for as long as the link stays up.
  static const Duration defaultHoldRecheck = Duration(seconds: 15);

  final Future<DeviceRuntimeStatus> Function() readStatus;

  /// A reason while an SOS, pre-SOS, TAG countdown, ambiguous prompt or SOS
  /// delivery is open (or cannot be ruled out); null when idle.
  final Future<String?> Function() sosHold;

  /// A reason the radio must not be written or the TAG rebooted now
  /// (native link owner, OTA, provisioning, migration, DMP...); null when ok.
  final Future<String?> Function() radioWriteHold;

  /// When the TAG last sent an SOS frame on this link, if ever.
  final DateTime? Function() lastSosFrameAt;

  final TagVolumeStore volumeStore;
  final Future<void> Function(int volume) sendNotificationVolume;
  final Future<void> Function(int volume) sendSosVolume;

  /// The same source as provisioning (location → country → device-configs).
  final Future<StrictDeviceProvisioningConfig> Function()
  fetchProvisioningConfig;

  /// Writes one ACK-bearing frame and returns the TAG's E9 7A outcome
  /// (OK_NOCHANGE allowed); throws on reject, timeout or a lost link.
  final Future<ProvisioningCommandOutcome> Function(int opcode, List<int> bytes)
  sendAckCommand;

  final Future<void> Function() reboot;

  /// Returns the BLE contract version active on this connection.
  final Future<int> Function()? contractHandshake;
  final void Function(TagSosEvidenceReported evidence)? onSosEvidence;
  final TagSessionSosEvidence Function(DeviceRuntimeStatus status) sosEvidence;
  final Duration quietWindow;
  final Duration holdRecheck;

  /// How long a TAG whose repair failed (or cannot apply) is left alone,
  /// across app restarts.
  final Duration repairBlockCooldown;
  final TagRadioRepairLedger _ledger;

  final bool Function() _isLinkUp;
  final DateTime Function() _clock;
  final Timer Function(Duration, void Function()) _timer;
  final StreamController<TagSessionBootstrapEvent> _events =
      StreamController<TagSessionBootstrapEvent>.broadcast();

  _Session? _session;
  bool _disposed = false;

  Stream<TagSessionBootstrapEvent> get events => _events.stream;

  static bool _alwaysUp() => true;

  static TagSessionSosEvidence _evidenceFromStatus(
    DeviceRuntimeStatus status,
  ) => TagSessionSosEvidence.fromStatusReply(status.rawBytes);

  /// Runs once per [sessionId] (one TAG connection). A new id ends the
  /// previous session. [deviceKeys] are the TAG's known keys, most stable
  /// first; the first one identifies the TAG for radio repair bookkeeping.
  Future<void> start({
    required String sessionId,
    required List<String> deviceKeys,
  }) async {
    if (_disposed || deviceKeys.isEmpty || _session?.id == sessionId) return;
    stop();
    final session = _Session(
      id: sessionId,
      deviceKeys: deviceKeys,
      connectedAt: _clock(),
    );
    _session = session;
    await _run(session);
  }

  /// The link dropped: pending work of this connection is abandoned.
  void stop() {
    _session?.quietTimer?.cancel();
    _session?.holdTimer?.cancel();
    _session = null;
  }

  /// An SOS, countdown or prompt may have closed: resume deferred work.
  void safetyMayHaveCleared() {
    final session = _session;
    if (session != null && session.tailPending) {
      unawaited(_runTail(session));
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    stop();
    await _events.close();
  }

  bool _isCurrent(_Session session) =>
      !_disposed && identical(_session, session) && _isLinkUp();

  Future<void> _run(_Session session) async {
    final handshake = contractHandshake;
    if (handshake != null) {
      var version = 1;
      try {
        version = await handshake();
      } catch (_) {
        // §7.1: no OK = the connection stays on v1.
      }
      if (!_isCurrent(session)) return;
      session.contractVersion = version;
      _emit(TagSessionBootstrapCode.contractNegotiated, reason: 'v$version');
    }
    final status = await _read(session);
    if (status == null) return;

    // Safety first: the TAG's own SOS state decides stale/new.
    _applySosEvidence(session, status, announce: true);

    final mark = await _readMark(session);
    if (!_isCurrent(session)) return;
    if (mark?.state == TagRadioRepairState.awaitingVerification) {
      if (_radioSuspect(status)) {
        await _mark(session, TagRadioRepairState.blocked);
        _emit(TagSessionBootstrapCode.radioRepairFailed);
      } else {
        await _mark(session, null);
        _emit(TagSessionBootstrapCode.radioRepairVerified);
      }
      if (!_isCurrent(session)) return;
    }
    await _runTail(session);
  }

  void _applySosEvidence(
    _Session session,
    DeviceRuntimeStatus status, {
    required bool announce,
  }) {
    switch (sosEvidence(status)) {
      case TagSosEvidenceUnavailable():
        // Under the v2 contract the TAG must report its state; a reply that
        // does not is not proof of "no SOS" (doc 36 §9: discard, ask again).
        session.tagHold = session.contractVersion >= 2
            ? 'tag_sos_unknown'
            : null;
        if (announce) _emit(TagSessionBootstrapCode.sosEvidenceUnavailable);
      case final TagSosEvidenceReported reported:
        session.tagHold = reported.sosState.isOpen ? 'tag_sos_reported' : null;
        if (announce) {
          _emit(
            TagSessionBootstrapCode.sosEvidenceReported,
            reason: reported.sosState.name,
          );
          onSosEvidence?.call(reported);
        }
    }
  }

  Future<DeviceRuntimeStatus?> _read(_Session session) async {
    try {
      final status = await readStatus();
      if (!_isCurrent(session)) return null;
      session.status = status;
      return status;
    } catch (_) {
      if (_isCurrent(session)) {
        _emit(TagSessionBootstrapCode.statusReadFailed);
      }
      return null;
    }
  }

  Future<void> _runTail(_Session session) async {
    if (!_isCurrent(session)) return;
    if (session.tailRunning) {
      session.tailRerun = true;
      return;
    }
    session.tailRunning = true;
    try {
      do {
        session.tailRerun = false;
        if (session.tagHold != null) {
          // The TAG said it is in SOS (or did not say): re-read until it
          // says otherwise.
          final fresh = await _read(session);
          if (fresh != null) {
            _applySosEvidence(session, fresh, announce: false);
          }
        }
        final hold = session.tagHold ?? await sosHold();
        if (!_isCurrent(session)) return;
        if (hold != null) {
          if (!session.tailPending || session.lastHoldReason != hold) {
            _emit(TagSessionBootstrapCode.deferredForSafety, reason: hold);
          }
          session
            ..tailPending = true
            ..lastHoldReason = hold;
          if (session.holdTimer?.isActive != true) {
            session.holdTimer = _timer(holdRecheck, () {
              if (_isCurrent(session)) unawaited(_runTail(session));
            });
          }
          return;
        }
        session
          ..tailPending = false
          ..lastHoldReason = null;
        if (!session.volumeDone) await _restoreVolume(session);
        if (!_isCurrent(session)) return;
        if (!session.radioDone) await _checkRadio(session);
      } while (session.tailRerun && _isCurrent(session));
    } finally {
      session.tailRunning = false;
    }
  }

  Future<void> _restoreVolume(_Session session) async {
    session.volumeDone = true;
    final TagVolumes? stored;
    try {
      stored = await volumeStore.read(session.deviceKeys);
    } catch (_) {
      _emit(TagSessionBootstrapCode.volumeStoreReadFailed);
      return;
    }
    if (!_isCurrent(session)) return;
    if (stored == null || stored.isEmpty) {
      _emit(TagSessionBootstrapCode.volumeNotStored);
      return;
    }
    try {
      final notify = stored.notification;
      if (notify != null) await sendNotificationVolume(notify);
      final sos = stored.sos;
      if (sos != null && _isCurrent(session)) await sendSosVolume(sos);
      if (_isCurrent(session)) _emit(TagSessionBootstrapCode.volumeRestored);
    } catch (_) {
      if (_isCurrent(session)) {
        _emit(TagSessionBootstrapCode.volumeWriteFailed, reason: 'write');
      }
    }
  }

  /// Live-status test only: `use_preset` set, or a live mesh SF that no
  /// provisioning config for the TAG's region can produce. Frequency,
  /// bandwidth, CR and power are not in status v2.
  bool _radioSuspect(DeviceRuntimeStatus status) {
    if (!status.isProvisioned) return false;
    if (status.usePreset) return true;
    final range = provisioningTelSpreadingFactorRange(status.region);
    return range != null &&
        (status.meshSpreadingFactor < range.min ||
            status.meshSpreadingFactor > range.max);
  }

  /// The TAG has been connected and silent (no SOS frame) for [quietWindow].
  Duration _quietRemaining(_Session session) {
    final lastFrame = lastSosFrameAt();
    final quietSince =
        lastFrame != null && lastFrame.isAfter(session.connectedAt)
        ? lastFrame
        : session.connectedAt;
    final remaining = quietSince.add(quietWindow).difference(_clock());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Future<void> _checkRadio(_Session session) async {
    final status = session.status;
    if (status == null || !status.isProvisioned) {
      // Not provisioned: the provisioning flow owns the radio.
      session.radioDone = true;
      return;
    }
    if (!status.txEnabled) {
      // tx_enabled is not part of the RF block: our frames cannot fix it.
      session.radioDone = true;
      _emit(TagSessionBootstrapCode.radioTxDisabled);
      return;
    }
    if (!_radioSuspect(status)) {
      session.radioDone = true;
      _emit(TagSessionBootstrapCode.radioOk);
      return;
    }
    final mark = await _readMark(session);
    if (!_isCurrent(session)) return;
    if (mark?.state == TagRadioRepairState.blocked &&
        _clock().difference(mark!.at) < repairBlockCooldown) {
      session.radioDone = true;
      _emit(TagSessionBootstrapCode.radioRepairSkipped, reason: 'blocked');
      return;
    }
    final remaining = _quietRemaining(session);
    if (remaining > Duration.zero) {
      if (session.quietTimer?.isActive != true) {
        _emit(TagSessionBootstrapCode.radioAwaitingQuietTag);
        session.quietTimer = _timer(remaining, () {
          if (_isCurrent(session)) unawaited(_runTail(session));
        });
      }
      return;
    }
    // At most one repair attempt per connection, whatever happens next.
    session.radioDone = true;
    final fresh = await _read(session);
    if (fresh == null) return;
    _applySosEvidence(session, fresh, announce: false);
    final tagHold = session.tagHold;
    if (tagHold != null) {
      _emit(TagSessionBootstrapCode.radioRepairSkipped, reason: tagHold);
      return;
    }
    if (!_radioSuspect(fresh) || !fresh.txEnabled) {
      _emit(TagSessionBootstrapCode.radioOk);
      return;
    }
    await _repair(session, fresh);
  }

  /// Null when the radio may be written and the TAG rebooted right now.
  Future<String?> _writeGate(_Session session) async {
    if (!_isCurrent(session)) return 'link_lost';
    final tagHold = session.tagHold;
    if (tagHold != null) return tagHold;
    final sos = await sosHold();
    if (sos != null) return sos;
    final radio = await radioWriteHold();
    if (radio != null) return radio;
    if (!_isCurrent(session)) return 'link_lost';
    if (_quietRemaining(session) > Duration.zero) return 'sos_frame_seen';
    return null;
  }

  Future<void> _repair(_Session session, DeviceRuntimeStatus status) async {
    final gate = await _writeGate(session);
    if (gate != null) {
      if (_isCurrent(session)) {
        _emit(TagSessionBootstrapCode.radioRepairSkipped, reason: gate);
      }
      return;
    }
    final StrictDeviceProvisioningConfig config;
    try {
      config = await fetchProvisioningConfig();
    } catch (_) {
      if (_isCurrent(session)) {
        _emit(
          TagSessionBootstrapCode.radioRepairSkipped,
          reason: 'config_unavailable',
        );
      }
      return;
    }
    if (!_isCurrent(session)) return;
    if (status.region != config.regionCode) {
      // A region change needs the user's confirmation (country check).
      _emit(
        TagSessionBootstrapCode.radioRepairSkipped,
        reason: 'region_mismatch',
      );
      return;
    }
    if (!status.usePreset &&
        status.meshSpreadingFactor == config.sos.spreadingFactor) {
      // While in SOS the TAG's live radio runs the SOS PHY, whose SF can lie
      // outside the TEL envelope: that is an SOS, not a wrong radio.
      _emit(
        TagSessionBootstrapCode.radioRepairSkipped,
        reason: 'sos_phy_possible',
      );
      return;
    }
    final preWrite = await _writeGate(session);
    if (preWrite != null) {
      if (_isCurrent(session)) {
        _emit(TagSessionBootstrapCode.radioRepairSkipped, reason: preWrite);
      }
      return;
    }

    _emit(TagSessionBootstrapCode.radioRepairStarted);
    await _mark(session, TagRadioRepairState.awaitingVerification);
    final ProvisioningCommandOutcome radio;
    try {
      radio = await sendAckCommand(0x20, encodeFullRadioConfig(config));
    } catch (_) {
      await _failWrite(session, 'radio');
      return;
    }
    if (radio == ProvisioningCommandOutcome.okNoChange) {
      // Firmware compared the saved config with ours and found it equal.
      // With use_preset still set it ignored the RF block (old firmware);
      // otherwise the saved radio is already right and the live SF is not
      // a config problem (it applies at the TAG's next reboot anyway).
      // Never reboot on it.
      await _mark(session, TagRadioRepairState.blocked);
      if (status.usePreset) {
        _emit(TagSessionBootstrapCode.radioRepairNotApplied);
      } else {
        _emit(
          TagSessionBootstrapCode.radioRepairSkipped,
          reason: 'saved_config_matches',
        );
      }
      return;
    }
    if (await _skipRebootIfUnsafe(session)) return;
    try {
      await sendAckCommand(0x21, encodeSosRadioConfig(config));
    } catch (_) {
      await _failWrite(session, 'sos_radio');
      return;
    }
    if (await _skipRebootIfUnsafe(session)) return;
    _emit(TagSessionBootstrapCode.radioRepairRebooting);
    try {
      await reboot();
    } catch (_) {
      // The link often drops before the write completes; the next
      // connection verifies either way.
    }
  }

  /// The config is saved on the TAG but not applied until it reboots. If the
  /// reboot is unsafe now, skip it: the TAG applies it at its next reboot, and
  /// the next connection may repair again (nothing was rebooted, no loop).
  Future<bool> _skipRebootIfUnsafe(_Session session) async {
    final gate = await _writeGate(session);
    if (gate == null) return false;
    await _mark(session, null);
    _emit(TagSessionBootstrapCode.radioRepairRebootSkipped, reason: gate);
    return true;
  }

  Future<void> _failWrite(_Session session, String step) async {
    await _mark(session, TagRadioRepairState.blocked);
    _emit(TagSessionBootstrapCode.radioRepairWriteFailed, reason: step);
  }

  Future<TagRadioRepairMark?> _readMark(_Session session) async {
    try {
      return await _ledger.read(session.deviceKeys);
    } catch (_) {
      // Unreadable: fail closed, no repair this connection.
      return TagRadioRepairMark(TagRadioRepairState.blocked, _clock());
    }
  }

  Future<void> _mark(_Session session, TagRadioRepairState? state) async {
    try {
      await _ledger.write(
        session.deviceKeys,
        state == null ? null : TagRadioRepairMark(state, _clock()),
      );
    } catch (_) {
      // Best effort; the per-connection limit still holds.
    }
  }

  void _emit(TagSessionBootstrapCode code, {String? reason}) {
    if (_disposed) return;
    sdkReleaseLog(
      'TAG_SESSION_BOOTSTRAP code=${code.wire}'
      '${reason == null ? '' : ' reason=$reason'}',
    );
    _events.add(TagSessionBootstrapEvent(code, reason: reason));
  }
}

final class _Session {
  _Session({
    required this.id,
    required this.deviceKeys,
    required this.connectedAt,
  });

  final String id;
  final List<String> deviceKeys;
  final DateTime connectedAt;
  DeviceRuntimeStatus? status;
  int contractVersion = 1;

  /// Set while the TAG's own status says (or, under contract v2, fails to
  /// say) that it is in SOS.
  String? tagHold;
  bool volumeDone = false;
  bool radioDone = false;
  bool tailPending = false;
  bool tailRunning = false;
  bool tailRerun = false;
  String? lastHoldReason;
  Timer? quietTimer;
  Timer? holdTimer;
}
