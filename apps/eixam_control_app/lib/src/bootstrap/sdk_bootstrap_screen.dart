import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_shell/eixam_demo_app.dart';
import '../protection/android_protection_platform_adapter.dart';
import 'validation_backend_config.dart';
import 'validation_backend_config_store.dart';

class SdkBootstrapScreen extends StatefulWidget {
  const SdkBootstrapScreen({super.key});

  @override
  State<SdkBootstrapScreen> createState() => _SdkBootstrapScreenState();
}

class _SdkBootstrapScreenState extends State<SdkBootstrapScreen> {
  bool _isLoading = false;
  String? _error;
  String? _stackTrace;
  EixamConnectSdk? _sdk;
  int _sdkGeneration = 0;
  final ValidationBackendConfigStore _configStore =
      ValidationBackendConfigStore();
  ValidationBackendConfig? _activeConfig;
  StreamSubscription<ProtectionPlatformEvent>? _protectionRuntimeSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeBootstrap());
  }

  Future<void> _initializeBootstrap() async {
    final config = await _configStore.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _activeConfig = config;
    });
    await _bootstrapSdk(config: config);
  }

  Future<void> _bootstrapSdk({ValidationBackendConfig? config}) async {
    final nextConfig =
        config ?? _activeConfig ?? ValidationBackendConfig.production;
    debugPrint(
      'SDK bootstrap start -> backend=${nextConfig.label} api=${nextConfig.apiBaseUrl} mqtt=${nextConfig.mqttWebsocketUrl}',
    );
    setState(() {
      _isLoading = true;
      _error = null;
      _stackTrace = null;
      _activeConfig = nextConfig;
    });

    try {
      final previousSdk = _sdk;
      final protectionPlatformAdapter = _buildProtectionPlatformAdapter();
      final sdk = await ApiSdkFactory.createHttpApi(
        apiBaseUrl: nextConfig.apiBaseUrl,
        websocketUrl: nextConfig.mqttWebsocketUrl,
        protectionPlatformAdapter: protectionPlatformAdapter,
      );
      await _bindProtectionRuntimeHooks(
        sdk: sdk,
        platformAdapter: protectionPlatformAdapter,
      );
      await sdk.rehydrateProtectionState();
      debugPrint(
        'SDK bootstrap ready -> backend=${nextConfig.label} disposing_previous=${previousSdk != null}',
      );
      await _disposeSdk(previousSdk);
      if (!mounted) return;
      setState(() {
        _sdk = sdk;
        _isLoading = false;
        _sdkGeneration++;
      });
      debugPrint(
        'SDK bootstrap applied -> generation=$_sdkGeneration backend=${nextConfig.label}',
      );
    } catch (error, stackTrace) {
      debugPrint('SDK bootstrap failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _stackTrace = stackTrace.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _reconfigureBackend(ValidationBackendConfig config) async {
    debugPrint(
      'Backend reconfigure requested -> backend=${config.label} api=${config.apiBaseUrl}',
    );
    await _configStore.save(config);
    await _bootstrapSdk(config: config);
  }

  Future<void> _disposeSdk(EixamConnectSdk? sdk) async {
    await _protectionRuntimeSub?.cancel();
    _protectionRuntimeSub = null;
    if (sdk is EixamConnectSdkImpl) {
      debugPrint('Disposing previous SDK instance...');
      await sdk.dispose();
      debugPrint('Previous SDK instance disposed.');
    }
  }

  ProtectionPlatformAdapter? _buildProtectionPlatformAdapter() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    return AndroidProtectionPlatformAdapter();
  }

  Future<void> _bindProtectionRuntimeHooks({
    required EixamConnectSdk sdk,
    ProtectionPlatformAdapter? platformAdapter,
  }) async {
    await _protectionRuntimeSub?.cancel();
    _protectionRuntimeSub = null;
    if (platformAdapter == null) {
      return;
    }

    _protectionRuntimeSub = platformAdapter.watchPlatformEvents().listen(
      (event) {
        final shouldRehydrate =
            event.type == ProtectionPlatformEventType.woke ||
                event.type == ProtectionPlatformEventType.runtimeStarted ||
                event.type == ProtectionPlatformEventType.runtimeRecovered ||
                event.type == ProtectionPlatformEventType.runtimeRestarted ||
                event.type == ProtectionPlatformEventType.bluetoothTurnedOff ||
                event.type == ProtectionPlatformEventType.bluetoothTurnedOn;
        if (!shouldRehydrate) {
          return;
        }
        unawaited(sdk.rehydrateProtectionState());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final sdk = _sdk;
    final activeConfig = _activeConfig;
    if (sdk != null && activeConfig != null) {
      return EixamDemoApp(
        sdk: sdk,
        sdkGeneration: _sdkGeneration,
        backendConfig: activeConfig,
        onReconfigureBackend: _reconfigureBackend,
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('EIXAM Control Demo')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.health_and_safety_outlined, size: 56),
                  const SizedBox(height: 16),
                  const Text(
                    'EIXAM SDK bootstrap diagnostic',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Initialize the SDK first, then choose an operational or technical validation surface.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading
                          ? null
                          : () => _bootstrapSdk(config: activeConfig),
                      child: Text(
                        _isLoading ? 'Bootstrapping SDK...' : 'Start SDK',
                      ),
                    ),
                  ),
                  if (activeConfig != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Active backend: ${activeConfig.label} (${activeConfig.apiBaseUrl})',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'MQTT URL: ${activeConfig.mqttWebsocketUrl}',
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_error != null)
                    _DiagnosticBox(
                      background: Colors.red.withValues(alpha: 0.08),
                      border: Colors.red.withValues(alpha: 0.3),
                      child: SelectableText('SDK bootstrap error:\n\n$_error'),
                    ),
                  if (_stackTrace != null) ...[
                    const SizedBox(height: 16),
                    _DiagnosticBox(
                      background: Colors.black.withValues(alpha: 0.04),
                      border: Colors.black.withValues(alpha: 0.12),
                      child: SelectableText(
                        _stackTrace!,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_disposeSdk(_sdk));
    super.dispose();
  }
}

class _DiagnosticBox extends StatelessWidget {
  const _DiagnosticBox({
    required this.background,
    required this.border,
    required this.child,
  });

  final Color background;
  final Color border;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: child,
    );
  }
}
