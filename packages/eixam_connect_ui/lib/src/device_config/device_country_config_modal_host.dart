import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/material.dart';

import '../localization/eixam_ui_scope.dart';
import '../localization/eixam_ui_texts.dart';

/// Wraps [child] and shows an emergent modal that mirrors the SDK's per-country
/// device radio-config apply: loading while a region change is in progress,
/// then success or error.
///
/// SDK-owned so host apps stay thin: feed it
/// `sdk.watchDeviceCountryConfigStatus()` and it does the rest. Copy comes from
/// [EixamUiScope] (or the [texts] override), so no app-side localization is
/// needed. The modal is EMERGENT: it only appears once a real apply starts
/// ([DeviceCountryConfigStatus.isApplying]); the transparent skip outcomes
/// (up-to-date, offline, no-location, …) never surface it.
class DeviceCountryConfigModalHost extends StatefulWidget {
  const DeviceCountryConfigModalHost({
    super.key,
    required this.statusStream,
    required this.child,
    this.texts,
    this.successAutoDismiss = const Duration(milliseconds: 2500),
  });

  final Stream<DeviceCountryConfigStatus> statusStream;
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
  Timer? _dismissTimer;
  DeviceCountryConfigStatus? _current;
  bool _sawApplying = false;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(DeviceCountryConfigModalHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statusStream != widget.statusStream) {
      _subscribe();
    }
  }

  void _subscribe() {
    _sub?.cancel();
    _sub = widget.statusStream.listen(_onStatus);
  }

  void _onStatus(DeviceCountryConfigStatus status) {
    if (status.isApplying) {
      _dismissTimer?.cancel();
      setState(() {
        _sawApplying = true;
        _current = status;
        _visible = true;
      });
      return;
    }
    // Only surface the terminal state if we actually witnessed an apply start,
    // so a stale "applied" from a previous session never pops on launch.
    if (!_sawApplying) {
      return;
    }
    if (status.isApplied) {
      setState(() {
        _current = status;
        _visible = true;
      });
      _dismissTimer?.cancel();
      _dismissTimer = Timer(widget.successAutoDismiss, _dismiss);
    } else if (status.isFailure) {
      _dismissTimer?.cancel();
      setState(() {
        _current = status;
        _visible = true;
      });
    }
  }

  void _dismiss() {
    _dismissTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      _visible = false;
      _sawApplying = false;
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _sub?.cancel();
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
            texts: widget.texts ?? EixamUiScope.textsOf(context),
            onDismiss: _dismiss,
          ),
      ],
    );
  }
}

class _DeviceRegionModal extends StatelessWidget {
  const _DeviceRegionModal({
    required this.status,
    required this.texts,
    required this.onDismiss,
  });

  final DeviceCountryConfigStatus status;
  final EixamUiTexts texts;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool applying = status.isApplying;
    final bool failure = status.isFailure;

    final Widget leading;
    final String message;
    if (applying) {
      leading = const SizedBox(
        width: 40,
        height: 40,
        child: CircularProgressIndicator(strokeWidth: 3),
      );
      message = texts.deviceRegionApplying;
    } else if (failure) {
      leading =
          Icon(Icons.error_outline, size: 44, color: theme.colorScheme.error);
      message = texts.deviceRegionError;
    } else {
      leading =
          const Icon(Icons.check_circle_outline, size: 44, color: Colors.green);
      message = texts.deviceRegionSuccess;
    }

    return Positioned.fill(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: texts.deviceRegionTitle,
        child: ColoredBox(
          color: Colors.black54,
          child: Center(
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
                        if (failure) ...<Widget>[
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
        ),
      ),
    );
  }
}
