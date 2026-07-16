import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/material.dart';

import '../localization/eixam_ui_scope.dart';
import '../localization/eixam_ui_texts.dart';

/// Wraps [child] and owns the user-facing device-region flow: confirmation,
/// loading, success and error.
///
/// Confirmation is mandatory because the device must use the radio region
/// required by local regulations. SDK-owned so host apps stay thin: feed it
/// `sdk.watchDeviceCountryConfigStatus()`, call
/// `sdk.applyPendingDeviceCountryConfig()` from [onConfirm], and it does the
/// rest. Copy comes from [EixamUiScope] (or the [texts] override), so host apps
/// do not expose protocol terminology. Detection-only skips remain
/// transparent; a retryable gate encountered after confirmation is shown with
/// a retry action.
class DeviceCountryConfigModalHost extends StatefulWidget {
  const DeviceCountryConfigModalHost({
    super.key,
    required this.statusStream,
    required this.onConfirm,
    required this.child,
    this.supplementalStatusStream,
    this.texts,
    this.successAutoDismiss = const Duration(milliseconds: 2500),
  });

  final Stream<DeviceCountryConfigStatus> statusStream;

  /// Optional host-provided statuses, intended for development previews. The
  /// production SDK stream remains [statusStream].
  final Stream<DeviceCountryConfigStatus>? supplementalStatusStream;
  final Future<DeviceCountryConfigStatus> Function() onConfirm;
  final Widget child;

  /// Explicit copy; when null it is resolved from the [EixamUiScope].
  final EixamUiTexts? texts;

  /// How long the success state stays before auto-dismissing.
  final Duration successAutoDismiss;

  @override
  State<DeviceCountryConfigModalHost> createState() =>
      _DeviceCountryConfigModalHostState();
}

class _DeviceCountryConfigModalHostState
    extends State<DeviceCountryConfigModalHost> {
  StreamSubscription<DeviceCountryConfigStatus>? _sub;
  StreamSubscription<DeviceCountryConfigStatus>? _supplementalSub;
  Timer? _dismissTimer;
  DeviceCountryConfigStatus? _current;
  bool _applyAttempted = false;
  bool _confirming = false;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(DeviceCountryConfigModalHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statusStream != widget.statusStream ||
        oldWidget.supplementalStatusStream != widget.supplementalStatusStream) {
      _subscribe();
    }
  }

  void _subscribe() {
    _sub?.cancel();
    _supplementalSub?.cancel();
    _sub = widget.statusStream.listen(_onStatus);
    _supplementalSub = widget.supplementalStatusStream?.listen(_onStatus);
  }

  void _onStatus(DeviceCountryConfigStatus status) {
    if (status.requiresConfirmation) {
      _dismissTimer?.cancel();
      setState(() {
        _applyAttempted = false;
        _confirming = false;
        _current = status;
        _visible = true;
      });
      return;
    }
    if (status.isApplying) {
      _dismissTimer?.cancel();
      setState(() {
        _applyAttempted = true;
        _confirming = false;
        _current = status;
        _visible = true;
      });
      return;
    }
    // A detection-only terminal status replaces the confirmation that was on
    // screen (for example, a foreground re-check found no authoritative
    // location). Close it instead of letting the user confirm a plan the SDK
    // has deliberately invalidated.
    if (!status.applyAttempted) {
      if (_visible) {
        _dismiss();
      }
      return;
    }
    // Only surface terminal state if this host witnessed a confirmation/apply,
    // so stale success or skip snapshots never pop on launch.
    if (!_applyAttempted) {
      return;
    }
    final success =
        status.isApplied ||
        status.outcome == DeviceCountryConfigOutcome.skippedUpToDate;
    if (success) {
      setState(() {
        _confirming = false;
        _current = status;
        _visible = true;
      });
      _dismissTimer?.cancel();
      _dismissTimer = Timer(widget.successAutoDismiss, _dismiss);
    } else if (status.isTerminal) {
      _dismissTimer?.cancel();
      setState(() {
        _confirming = false;
        _current = status;
        _visible = true;
      });
    }
  }

  Future<void> _confirm() async {
    if (_confirming) {
      return;
    }
    _dismissTimer?.cancel();
    setState(() {
      _applyAttempted = true;
      _confirming = true;
    });
    try {
      final result = await widget.onConfirm();
      if (mounted) {
        final status = result.outcome == DeviceCountryConfigOutcome.idle
            ? result.copyWith(
                outcome: DeviceCountryConfigOutcome.failed,
                applyAttempted: true,
                canRetry: false,
                updatedAt: DateTime.now(),
                detail: 'Host apply callback returned idle.',
              )
            : result;
        _onStatus(status);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final current = _current;
      _onStatus(
        (current ?? DeviceCountryConfigStatus.idle()).copyWith(
          outcome: DeviceCountryConfigOutcome.failed,
          applyAttempted: true,
          canRetry: false,
          updatedAt: DateTime.now(),
          detail: 'Host apply callback failed: $error',
        ),
      );
    }
  }

  void _dismiss() {
    _dismissTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      _visible = false;
      _applyAttempted = false;
      _confirming = false;
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _sub?.cancel();
    _supplementalSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _current;
    return Stack(
      children: <Widget>[
        widget.child,
        if (_visible && status != null)
          _DeviceRegionModal(
            status: status,
            confirming: _confirming,
            texts: widget.texts ?? EixamUiScope.textsOf(context),
            onConfirm: () => unawaited(_confirm()),
            onDismiss: _dismiss,
          ),
      ],
    );
  }
}

class _DeviceRegionModal extends StatelessWidget {
  const _DeviceRegionModal({
    required this.status,
    required this.confirming,
    required this.texts,
    required this.onConfirm,
    required this.onDismiss,
  });

  final DeviceCountryConfigStatus status;
  final bool confirming;
  final EixamUiTexts texts;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool awaitingConfirmation =
        status.requiresConfirmation && !confirming;
    final bool applying = status.isApplying || confirming;
    final bool success =
        status.isApplied ||
        status.outcome == DeviceCountryConfigOutcome.skippedUpToDate;
    final bool failure = !awaitingConfirmation && !applying && !success;

    final Widget leading;
    final String message;
    if (awaitingConfirmation) {
      leading = Icon(
        Icons.location_on_outlined,
        size: 44,
        color: theme.colorScheme.primary,
      );
      message = texts.deviceRegionPrompt;
    } else if (applying) {
      leading = const SizedBox(
        width: 40,
        height: 40,
        child: CircularProgressIndicator(strokeWidth: 3),
      );
      message = texts.deviceRegionApplying;
    } else if (failure) {
      leading = Icon(
        Icons.error_outline,
        size: 44,
        color: theme.colorScheme.error,
      );
      message = texts.deviceRegionError;
    } else {
      leading = const Icon(
        Icons.check_circle_outline,
        size: 44,
        color: Colors.green,
      );
      message = texts.deviceRegionSuccess;
    }

    return Positioned.fill(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: texts.deviceRegionTitle,
        child: Stack(
          children: <Widget>[
            const ModalBarrier(dismissible: false, color: Color(0xCC000000)),
            Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Material(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                elevation: 8,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        leading,
                        const SizedBox(height: 16),
                        Text(
                          texts.deviceRegionTitle,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          message,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                          if (awaitingConfirmation) ...<Widget>[
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: onConfirm,
                                child: Text(texts.deviceRegionConfirm),
                              ),
                            ),
                          ] else if (failure && status.canRetry) ...<Widget>[
                            const SizedBox(height: 16),
                            Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 8,
                              runSpacing: 8,
                              children: <Widget>[
                                TextButton(
                                  onPressed: onDismiss,
                                  child: Text(texts.deviceRegionDismiss),
                                ),
                                FilledButton(
                                  onPressed: onConfirm,
                                  child: Text(texts.deviceRegionRetry),
                                ),
                              ],
                            ),
                          ] else if (failure) ...<Widget>[
                          const SizedBox(height: 16),
                          TextButton(
                            onPressed: onDismiss,
                            child: Text(texts.deviceRegionDismiss),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }
}
