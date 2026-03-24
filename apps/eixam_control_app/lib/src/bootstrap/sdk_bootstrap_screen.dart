import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/material.dart';

import '../app_shell/eixam_demo_app.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrapSdk());
  }

  Future<void> _bootstrapSdk() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _stackTrace = null;
    });

    try {
      final sdk = await DemoSdkFactory.create();
      if (!mounted) return;
      setState(() {
        _sdk = sdk;
        _isLoading = false;
      });
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

  @override
  Widget build(BuildContext context) {
    final sdk = _sdk;
    if (sdk != null) {
      return EixamDemoApp(sdk: sdk);
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
                      onPressed: _isLoading ? null : _bootstrapSdk,
                      child: Text(
                        _isLoading ? 'Bootstrapping SDK...' : 'Start SDK',
                      ),
                    ),
                  ),
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
