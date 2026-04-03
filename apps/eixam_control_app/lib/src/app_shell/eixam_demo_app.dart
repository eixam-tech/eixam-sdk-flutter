import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_ui/eixam_connect_ui.dart';
import 'package:flutter/material.dart';

import '../bootstrap/validation_backend_config.dart';
import 'app_shell_screen.dart';
import '../features/operational_demo/operational_demo_screen.dart';
import '../features/technical_lab/technical_lab_screen.dart';

class EixamDemoApp extends StatefulWidget {
  const EixamDemoApp({
    super.key,
    required this.sdk,
    required this.sdkGeneration,
    required this.backendConfig,
    required this.onReconfigureBackend,
  });

  final EixamConnectSdk sdk;
  final int sdkGeneration;
  final ValidationBackendConfig backendConfig;
  final Future<void> Function(ValidationBackendConfig config)
      onReconfigureBackend;

  @override
  State<EixamDemoApp> createState() => _EixamDemoAppState();
}

class _EixamDemoAppState extends State<EixamDemoApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<BleNotificationNavigationRequest>? _notificationSub;

  @override
  void initState() {
    super.initState();
    debugPrint(
      'EixamDemoApp init -> backend=${widget.backendConfig.label} sdkHash=${identityHashCode(widget.sdk)}',
    );
    _bindNotificationNavigation();
  }

  @override
  void didUpdateWidget(covariant EixamDemoApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sdkChanged = !identical(oldWidget.sdk, widget.sdk);
    final backendChanged =
        oldWidget.backendConfig.apiBaseUrl != widget.backendConfig.apiBaseUrl ||
            oldWidget.backendConfig.mqttWebsocketUrl !=
                widget.backendConfig.mqttWebsocketUrl;
    if (!sdkChanged && !backendChanged) {
      return;
    }

    debugPrint(
      'EixamDemoApp update -> sdkChanged=$sdkChanged backendChanged=$backendChanged reloading validation shell',
    );
    _notificationSub?.cancel();
    _bindNotificationNavigation();
  }

  void _bindNotificationNavigation() {
    _notificationSub =
        widget.sdk.watchBleNotificationNavigationRequests().listen(
              _openTechnicalLabFromNotification,
            );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending =
          await widget.sdk.consumePendingBleNotificationNavigationRequest();
      if (!mounted || pending == null) return;
      _openTechnicalLabFromNotification(pending);
    });
  }

  void _openOperationalDemo() {
    _navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => OperationalDemoScreen(
          sdk: widget.sdk,
          sdkGeneration: widget.sdkGeneration,
          backendConfig: widget.backendConfig,
          onApplyBackendConfig: _reconfigureOperationalDemo,
          onOpenTechnicalLab: _openTechnicalLab,
        ),
      ),
    );
  }

  Future<void> _reconfigureOperationalDemo(
    ValidationBackendConfig config,
  ) async {
    await widget.onReconfigureBackend(config);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }

    debugPrint(
      'EixamDemoApp backend reconfigured -> returning to refreshed app shell with sdkHash=${identityHashCode(widget.sdk)}',
    );
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      return;
    }

    navigator.popUntil((route) => route.isFirst);
  }

  void _openTechnicalLab() {
    _navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => TechnicalLabScreen(sdk: widget.sdk),
      ),
    );
  }

  void _openTechnicalLabFromNotification(
    BleNotificationNavigationRequest request,
  ) {
    _navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => TechnicalLabScreen(
          sdk: widget.sdk,
          notificationRequest: request,
        ),
      ),
    );
  }

  @override
  void dispose() {
    debugPrint(
      'EixamDemoApp dispose -> backend=${widget.backendConfig.label} sdkHash=${identityHashCode(widget.sdk)}',
    );
    _notificationSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EixamUiScope(
      localeCode: 'es',
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        home: AppShellScreen(
          backendLabel: widget.backendConfig.label,
          backendUrl: widget.backendConfig.apiBaseUrl,
          onOpenOperationalDemo: _openOperationalDemo,
          onOpenTechnicalLab: _openTechnicalLab,
        ),
      ),
    );
  }
}
