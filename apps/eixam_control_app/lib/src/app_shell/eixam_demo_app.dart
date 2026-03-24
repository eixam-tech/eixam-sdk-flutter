import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_ui/eixam_connect_ui.dart';
import 'package:flutter/material.dart';

import 'app_shell_screen.dart';
import '../features/operational_demo/operational_demo_screen.dart';
import '../features/technical_lab/technical_lab_screen.dart';

class EixamDemoApp extends StatefulWidget {
  const EixamDemoApp({
    super.key,
    required this.sdk,
  });

  final EixamConnectSdk sdk;

  @override
  State<EixamDemoApp> createState() => _EixamDemoAppState();
}

class _EixamDemoAppState extends State<EixamDemoApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<BleNotificationNavigationRequest>? _notificationSub;

  @override
  void initState() {
    super.initState();
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
          onOpenTechnicalLab: _openTechnicalLab,
        ),
      ),
    );
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
          onOpenOperationalDemo: _openOperationalDemo,
          onOpenTechnicalLab: _openTechnicalLab,
        ),
      ),
    );
  }
}
