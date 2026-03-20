import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_ui/eixam_connect_ui.dart';
import 'package:flutter/material.dart';

import 'device_detail_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BootstrapApp());
}

class BootstrapApp extends StatelessWidget {
  const BootstrapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SdkBootstrapScreen(),
    );
  }
}

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
    } catch (e, st) {
      debugPrint('SDK bootstrap failed: $e');
      debugPrintStack(stackTrace: st);

      if (!mounted) return;

      setState(() {
        _error = e.toString();
        _stackTrace = st.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sdk != null) {
      return DemoApp(sdk: _sdk!);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('EIXAM Control Demo'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.health_and_safety_outlined,
                    size: 56,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'EIXAM SDK bootstrap diagnostic',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Press the button below to initialize the demo SDK and open the demo home page.',
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
                  if (_error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.red.withOpacity(0.3),
                        ),
                      ),
                      child: SelectableText(
                        'SDK bootstrap error:\n\n$_error',
                        textAlign: TextAlign.left,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_stackTrace != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.black.withOpacity(0.12),
                        ),
                      ),
                      child: SelectableText(
                        _stackTrace!,
                        textAlign: TextAlign.left,
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

class DemoApp extends StatelessWidget {
  const DemoApp({
    super.key,
    required this.sdk,
  });

  final EixamConnectSdk sdk;

  @override
  Widget build(BuildContext context) {
    return EixamUiScope(
      localeCode: 'es',
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          appBar: AppBar(
            title: const Text('EIXAM Control Demo'),
          ),
          body: DemoHomePage(sdk: sdk),
        ),
      ),
    );
  }
}

class DemoHomePage extends StatefulWidget {
  const DemoHomePage({
    super.key,
    required this.sdk,
  });

  final EixamConnectSdk sdk;

  @override
  State<DemoHomePage> createState() => _DemoHomePageState();
}

class _DemoHomePageState extends State<DemoHomePage> {
  PermissionState? _permissionState;
  TrackingState? _trackingState;
  TrackingPosition? _lastPosition;
  SosState? _sosState;
  SosIncident? _activeIncident;
  DeviceStatus? _deviceStatus;
  DeathManPlan? _activeDeathManPlan;
  List<EmergencyContact> _contacts = <EmergencyContact>[];
  RealtimeConnectionState? _realtimeConnectionState;
  RealtimeEvent? _lastRealtimeEvent;
  String? _lastError;

  StreamSubscription<TrackingPosition>? _positionSub;
  StreamSubscription<TrackingState>? _trackingStateSub;
  StreamSubscription<SosState>? _sosStateSub;
  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  StreamSubscription<DeathManPlan>? _deathManSub;
  StreamSubscription<List<EmergencyContact>>? _contactsSub;
  StreamSubscription<RealtimeConnectionState>? _realtimeConnectionSub;
  StreamSubscription<RealtimeEvent>? _realtimeEventsSub;
  StreamSubscription<BleNotificationNavigationRequest>?
      _bleNotificationNavigationSub;

  bool _loadingPermissions = false;
  bool _loadingTracking = false;
  bool _loadingSos = false;
  bool _loadingNotifications = false;
  bool _loadingDevice = false;
  bool _loadingDeathMan = false;
  bool _loadingContacts = false;

  EixamConnectSdk get sdk => widget.sdk;

  @override
  void initState() {
    super.initState();
    _bindStreams();
    _loadInitialState();
    _bindBleNotificationNavigation();
  }

  void _bindStreams() {
    _positionSub = sdk.watchPositions().listen(
      (position) {
        if (!mounted) return;
        setState(() {
          _lastPosition = position;
        });
      },
      onError: _handleStreamError,
    );

    _trackingStateSub = sdk.watchTrackingState().listen(
      (state) {
        if (!mounted) return;
        setState(() {
          _trackingState = state;
        });
      },
      onError: _handleStreamError,
    );

    _sosStateSub = sdk.watchSosState().listen(
      (state) {
        if (!mounted) return;
        setState(() {
          _sosState = state;
        });
      },
      onError: _handleStreamError,
    );

    _deviceStatusSub = sdk.watchDeviceStatus().listen(
      (status) {
        if (!mounted) return;
        setState(() {
          _deviceStatus = status;
        });
      },
      onError: _handleStreamError,
    );

    _deathManSub = sdk.watchDeathManPlans().listen(
      (plan) {
        if (!mounted) return;
        setState(() {
          _activeDeathManPlan = plan;
        });
      },
      onError: _handleStreamError,
    );

    _contactsSub = sdk.watchEmergencyContacts().listen(
      (contacts) {
        if (!mounted) return;
        setState(() {
          _contacts = contacts;
        });
      },
      onError: _handleStreamError,
    );

    _realtimeConnectionSub = sdk.watchRealtimeConnectionState().listen(
      (state) {
        if (!mounted) return;
        setState(() {
          _realtimeConnectionState = state;
        });
      },
      onError: _handleStreamError,
    );

    _realtimeEventsSub = sdk.watchRealtimeEvents().listen(
      (event) {
        if (!mounted) return;
        setState(() {
          _lastRealtimeEvent = event;
        });
      },
      onError: _handleStreamError,
    );
  }

  void _bindBleNotificationNavigation() {
    _bleNotificationNavigationSub =
        sdk.watchBleNotificationNavigationRequests().listen(
      (request) {
        if (!mounted) return;
        _openDeviceDetailFromNotification(request);
      },
      onError: _handleStreamError,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending =
          await sdk.consumePendingBleNotificationNavigationRequest();
      if (!mounted || pending == null) return;
      _openDeviceDetailFromNotification(pending);
    });
  }

  void _handleStreamError(Object error) {
    if (!mounted) return;
    setState(() {
      _lastError = error.toString();
    });
  }

  Future<void> _loadInitialState() async {
    try {
      final permissionState = await sdk.getPermissionState();
      final trackingState = await sdk.getTrackingState();
      final currentPosition = await sdk.getCurrentPosition();
      final sosState = await sdk.getSosState();
      final deviceStatus = await sdk.getDeviceStatus();
      final deathManPlan = await sdk.getActiveDeathManPlan();
      final contacts = await sdk.listEmergencyContacts();
      final realtimeConnectionState = await sdk.getRealtimeConnectionState();
      final lastRealtimeEvent = await sdk.getLastRealtimeEvent();

      if (!mounted) return;

      setState(() {
        _permissionState = permissionState;
        _trackingState = trackingState;
        _lastPosition = currentPosition;
        _sosState = sosState;
        _deviceStatus = deviceStatus;
        _activeDeathManPlan = deathManPlan;
        _contacts = contacts;
        _realtimeConnectionState = realtimeConnectionState;
        _lastRealtimeEvent = lastRealtimeEvent;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    }
  }

  Future<void> _refreshPermissions() async {
    setState(() {
      _loadingPermissions = true;
      _lastError = null;
    });

    try {
      final state = await sdk.getPermissionState();
      if (!mounted) return;
      setState(() {
        _permissionState = state;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingPermissions = false;
      });
    }
  }

  Future<void> _requestLocationPermission() async {
    setState(() {
      _loadingPermissions = true;
      _lastError = null;
    });

    try {
      final state = await sdk.requestLocationPermission();
      if (!mounted) return;
      setState(() {
        _permissionState = state;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingPermissions = false;
      });
    }
  }

  Future<void> _requestNotificationPermission() async {
    setState(() {
      _loadingPermissions = true;
      _lastError = null;
    });

    try {
      final state = await sdk.requestNotificationPermission();
      if (!mounted) return;
      setState(() {
        _permissionState = state;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingPermissions = false;
      });
    }
  }

  Future<void> _requestBluetoothPermission() async {
    setState(() {
      _loadingPermissions = true;
      _lastError = null;
    });

    try {
      final state = await sdk.requestBluetoothPermission();
      if (!mounted) return;
      setState(() {
        _permissionState = state;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingPermissions = false;
      });
    }
  }

  Future<void> _startTracking() async {
    setState(() {
      _loadingTracking = true;
      _lastError = null;
    });

    try {
      await sdk.startTracking();
      final trackingState = await sdk.getTrackingState();
      final currentPosition = await sdk.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _trackingState = trackingState;
        _lastPosition = currentPosition;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingTracking = false;
      });
    }
  }

  Future<void> _stopTracking() async {
    setState(() {
      _loadingTracking = true;
      _lastError = null;
    });

    try {
      await sdk.stopTracking();
      final trackingState = await sdk.getTrackingState();
      if (!mounted) return;
      setState(() {
        _trackingState = trackingState;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingTracking = false;
      });
    }
  }

  Future<void> _triggerSos() async {
    setState(() {
      _loadingSos = true;
      _lastError = null;
    });

    try {
      final incident = await sdk.triggerSos(
        message: 'Manual SOS triggered from demo',
        triggerSource: 'button_ui',
      );
      final sosState = await sdk.getSosState();

      if (!mounted) return;
      setState(() {
        _activeIncident = incident;
        _sosState = sosState;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingSos = false;
      });
    }
  }

  Future<void> _cancelSos() async {
    setState(() {
      _loadingSos = true;
      _lastError = null;
    });

    try {
      final incident = await sdk.cancelSos(
        reason: 'Cancelled from demo home page',
      );
      final sosState = await sdk.getSosState();

      if (!mounted) return;
      setState(() {
        _activeIncident = incident;
        _sosState = sosState;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingSos = false;
      });
    }
  }

  Future<void> _initializeNotifications() async {
    setState(() {
      _loadingNotifications = true;
      _lastError = null;
    });

    try {
      await sdk.initializeNotifications();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingNotifications = false;
      });
    }
  }

  Future<void> _showTestNotification() async {
    setState(() {
      _loadingNotifications = true;
      _lastError = null;
    });

    try {
      await sdk.showLocalNotification(
        title: 'EIXAM test notification',
        body: 'Local notifications are working in the demo app.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingNotifications = false;
      });
    }
  }

  Future<void> _ensureBleReadyForPairing() async {
    var state = await sdk.getPermissionState();
    if (!state.hasBluetoothAccess) {
      state = await sdk.requestBluetoothPermission();
    }
    if (!state.hasLocationAccess &&
        state.location != SdkPermissionStatus.serviceDisabled) {
      state = await sdk.requestLocationPermission();
    }
    if (!mounted) return;
    setState(() {
      _permissionState = state;
    });
  }

  Future<void> _pairDevice() async {
    setState(() {
      _loadingDevice = true;
      _lastError = null;
    });

    try {
      await _ensureBleReadyForPairing();
      final status = await sdk.pairDevice(pairingCode: 'DEMO-PAIR-001');
      if (!mounted) return;
      setState(() {
        _deviceStatus = status;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingDevice = false;
      });
    }
  }

  Future<void> _activateDevice() async {
    setState(() {
      _loadingDevice = true;
      _lastError = null;
    });

    try {
      final status = await sdk.activateDevice(activationCode: 'DEMO-ACT-001');
      if (!mounted) return;
      setState(() {
        _deviceStatus = status;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingDevice = false;
      });
    }
  }

  Future<void> _refreshDevice() async {
    setState(() {
      _loadingDevice = true;
      _lastError = null;
    });

    try {
      final status = await sdk.refreshDeviceStatus();
      if (!mounted) return;
      setState(() {
        _deviceStatus = status;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingDevice = false;
      });
    }
  }

  Future<void> _unpairDevice() async {
    setState(() {
      _loadingDevice = true;
      _lastError = null;
    });

    try {
      await sdk.unpairDevice();
      final status = await sdk.getDeviceStatus();
      if (!mounted) return;
      setState(() {
        _deviceStatus = status;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingDevice = false;
      });
    }
  }

  Future<void> _openDeviceDetail() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => DeviceDetailScreen(sdk: sdk),
      ),
    );
  }

  Future<void> _openDeviceDetailFromNotification(
    BleNotificationNavigationRequest request,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => DeviceDetailScreen(
          sdk: sdk,
          notificationContextMessage: request.reason,
          notificationActionId: request.actionId,
          notificationNodeId: request.nodeId,
        ),
      ),
    );
  }

  Future<void> _scheduleQuickDeathMan() async {
    setState(() {
      _loadingDeathMan = true;
      _lastError = null;
    });

    try {
      final plan = await sdk.scheduleDeathMan(
        expectedReturnAt: DateTime.now().add(const Duration(seconds: 20)),
        gracePeriod: const Duration(seconds: 10),
        checkInWindow: const Duration(seconds: 15),
        autoTriggerSos: true,
      );

      if (!mounted) return;
      setState(() {
        _activeDeathManPlan = plan;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingDeathMan = false;
      });
    }
  }

  Future<void> _confirmDeathMan() async {
    final plan = _activeDeathManPlan;
    if (plan == null) return;

    setState(() {
      _loadingDeathMan = true;
      _lastError = null;
    });

    try {
      await sdk.confirmDeathManCheckIn(plan.id);
      final refreshed = await sdk.getActiveDeathManPlan();
      if (!mounted) return;
      setState(() {
        _activeDeathManPlan = refreshed;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingDeathMan = false;
      });
    }
  }

  Future<void> _cancelDeathMan() async {
    final plan = _activeDeathManPlan;
    if (plan == null) return;

    setState(() {
      _loadingDeathMan = true;
      _lastError = null;
    });

    try {
      await sdk.cancelDeathMan(plan.id);
      final refreshed = await sdk.getActiveDeathManPlan();
      if (!mounted) return;
      setState(() {
        _activeDeathManPlan = refreshed;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingDeathMan = false;
      });
    }
  }

  Future<void> _addSampleContact() async {
    setState(() {
      _loadingContacts = true;
      _lastError = null;
    });

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await sdk.addEmergencyContact(
        name: 'Sample Contact $now',
        phone: '+34123456789',
        email: 'sample$now@eixam.dev',
        priority: 1,
        active: true,
      );

      final contacts = await sdk.listEmergencyContacts();

      if (!mounted) return;
      setState(() {
        _contacts = contacts;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingContacts = false;
      });
    }
  }

  Future<void> _toggleFirstContact() async {
    if (_contacts.isEmpty) return;

    setState(() {
      _loadingContacts = true;
      _lastError = null;
    });

    try {
      final first = _contacts.first;
      await sdk.setEmergencyContactActive(first.id, !first.active);
      final contacts = await sdk.listEmergencyContacts();

      if (!mounted) return;
      setState(() {
        _contacts = contacts;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingContacts = false;
      });
    }
  }

  Future<void> _removeFirstContact() async {
    if (_contacts.isEmpty) return;

    setState(() {
      _loadingContacts = true;
      _lastError = null;
    });

    try {
      await sdk.removeEmergencyContact(_contacts.first.id);
      final contacts = await sdk.listEmergencyContacts();

      if (!mounted) return;
      setState(() {
        _contacts = contacts;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingContacts = false;
      });
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _trackingStateSub?.cancel();
    _sosStateSub?.cancel();
    _deviceStatusSub?.cancel();
    _deathManSub?.cancel();
    _contactsSub?.cancel();
    _realtimeConnectionSub?.cancel();
    _realtimeEventsSub?.cancel();
    _bleNotificationNavigationSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionCard(
            title: 'Realtime',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoLine(
                  label: 'Connection state',
                  value: _realtimeConnectionState?.name ?? 'Unknown',
                ),
                _InfoLine(
                  label: 'Last event type',
                  value: _lastRealtimeEvent?.type ?? '-',
                ),
                _InfoLine(
                  label: 'Last event timestamp',
                  value: _lastRealtimeEvent?.timestamp.toIso8601String() ?? '-',
                ),
                _InfoLine(
                  label: 'Last event payload',
                  value: _lastRealtimeEvent?.payload.toString() ?? '-',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Permissions',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoLine(
                  label: 'Location',
                  value: _permissionState == null
                      ? 'Unknown'
                      : '${_permissionState!.location}',
                ),
                _InfoLine(
                  label: 'Notifications',
                  value: _permissionState == null
                      ? 'Unknown'
                      : '${_permissionState!.notifications}',
                ),
                _InfoLine(
                  label: 'Bluetooth',
                  value: _permissionState == null
                      ? 'Unknown'
                      : '${_permissionState!.bluetooth}',
                ),
                _InfoLine(
                  label: 'Bluetooth enabled',
                  value: _permissionState == null
                      ? 'Unknown'
                      : '${_permissionState!.bluetoothEnabled}',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed:
                          _loadingPermissions ? null : _refreshPermissions,
                      child: const Text('Refresh'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingPermissions
                          ? null
                          : _requestLocationPermission,
                      child: const Text('Request location'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingPermissions
                          ? null
                          : _requestNotificationPermission,
                      child: const Text('Request notifications'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingPermissions
                          ? null
                          : _requestBluetoothPermission,
                      child: const Text('Request Bluetooth'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Notifications',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Initialize local notifications and send a test notification.',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: _loadingNotifications
                          ? null
                          : _initializeNotifications,
                      child: const Text('Init notifications'),
                    ),
                    ElevatedButton(
                      onPressed:
                          _loadingNotifications ? null : _showTestNotification,
                      child: const Text('Test notification'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Tracking',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoLine(
                  label: 'Tracking state',
                  value: _trackingState?.name ?? 'Unknown',
                ),
                _InfoLine(
                  label: 'Latitude',
                  value: _lastPosition?.latitude.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Longitude',
                  value: _lastPosition?.longitude.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Accuracy',
                  value: _lastPosition?.accuracy.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Source',
                  value: _lastPosition?.source.toString() ?? '-',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: _loadingTracking ? null : _startTracking,
                      child: const Text('Start tracking'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingTracking ? null : _stopTracking,
                      child: const Text('Stop tracking'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'SOS',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoLine(
                  label: 'SOS state',
                  value: _sosState?.name ?? 'Unknown',
                ),
                _InfoLine(
                  label: 'Incident ID',
                  value: _activeIncident?.id ?? '-',
                ),
                _InfoLine(
                  label: 'Trigger source',
                  value: _activeIncident?.triggerSource ?? '-',
                ),
                _InfoLine(
                  label: 'Message',
                  value: _activeIncident?.message ?? '-',
                ),
                _InfoLine(
                  label: 'Position snapshot',
                  value: _activeIncident?.positionSnapshot == null
                      ? '-'
                      : '${_activeIncident!.positionSnapshot!.latitude}, ${_activeIncident!.positionSnapshot!.longitude}',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: _loadingSos ? null : _triggerSos,
                      child: const Text('Trigger SOS'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingSos ? null : _cancelSos,
                      child: const Text('Cancel SOS'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Device',
            onTap: _openDeviceDetail,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoLine(
                  label: 'Lifecycle',
                  value: _deviceStatus?.lifecycleState.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Paired',
                  value: _deviceStatus?.paired.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Connected',
                  value: _deviceStatus?.connected.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Activated',
                  value: _deviceStatus?.activated.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Ready for safety',
                  value: _deviceStatus?.isReadyForSafety.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Model',
                  value: _deviceStatus?.model ?? '-',
                ),
                _InfoLine(
                  label: 'Alias',
                  value: _deviceStatus?.deviceAlias ?? '-',
                ),
                _InfoLine(
                  label: 'Battery',
                  value: _deviceStatus?.batteryLevel?.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Signal',
                  value: _deviceStatus?.signalQuality?.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Firmware',
                  value: _deviceStatus?.firmwareVersion ?? '-',
                ),
                const SizedBox(height: 4),
                const Text(
                  'Tap this card to open device detail and BLE debug tools.',
                  style: TextStyle(
                    color: Colors.black54,
                    fontSize: 12,
                  ),
                ),
                _InfoLine(
                  label: 'Provisioning error',
                  value: _deviceStatus?.provisioningError ?? '-',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: _loadingDevice ? null : _pairDevice,
                      child: const Text('Pair'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingDevice ? null : _activateDevice,
                      child: const Text('Activate'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingDevice ? null : _refreshDevice,
                      child: const Text('Refresh'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingDevice ? null : _unpairDevice,
                      child: const Text('Unpair'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Death Man Protocol',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoLine(
                  label: 'Plan ID',
                  value: _activeDeathManPlan?.id ?? '-',
                ),
                _InfoLine(
                  label: 'Status',
                  value: _activeDeathManPlan?.status.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Expected return',
                  value:
                      _activeDeathManPlan?.expectedReturnAt.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Grace period',
                  value: _activeDeathManPlan?.gracePeriod.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Check-in window',
                  value: _activeDeathManPlan?.checkInWindow.toString() ?? '-',
                ),
                _InfoLine(
                  label: 'Auto SOS',
                  value: _activeDeathManPlan?.autoTriggerSos.toString() ?? '-',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed:
                          _loadingDeathMan ? null : _scheduleQuickDeathMan,
                      child: const Text('Quick demo (20s)'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingDeathMan || _activeDeathManPlan == null
                          ? null
                          : _confirmDeathMan,
                      child: const Text('Confirm safe'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingDeathMan || _activeDeathManPlan == null
                          ? null
                          : _cancelDeathMan,
                      child: const Text('Cancel plan'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Emergency Contacts',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoLine(
                  label: 'Total contacts',
                  value: _contacts.length.toString(),
                ),
                if (_contacts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ..._contacts.take(3).map(
                        (contact) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '${contact.name} · active=${contact.active} · priority=${contact.priority}',
                          ),
                        ),
                      ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: _loadingContacts ? null : _addSampleContact,
                      child: const Text('Add sample'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingContacts || _contacts.isEmpty
                          ? null
                          : _toggleFirstContact,
                      child: const Text('Toggle first'),
                    ),
                    ElevatedButton(
                      onPressed: _loadingContacts || _contacts.isEmpty
                          ? null
                          : _removeFirstContact,
                      child: const Text('Remove first'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_lastError != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.red.withOpacity(0.3),
                ),
              ),
              child: SelectableText(
                'Last error:\n\n$_lastError',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.onTap,
  });

  final String title;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (onTap != null)
                    const Icon(
                      Icons.chevron_right,
                      color: Colors.black54,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style,
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}
