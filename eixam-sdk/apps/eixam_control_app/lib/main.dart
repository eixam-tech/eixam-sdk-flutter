import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_ui/eixam_connect_ui.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sdk = await ApiSdkFactory.createMockApi();
  runApp(DemoApp(sdk: sdk));
}

class DemoApp extends StatelessWidget {
  final EixamConnectSdk sdk;

  const DemoApp({super.key, required this.sdk});

  @override
  Widget build(BuildContext context) {
    return EixamUiScope(
      localeCode: 'es',
      overrides: EixamUiTexts.es().copyWith(
        sosSending: 'Sending SOS to the control center...',
        sosSent: 'SOS sent successfully',
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: DemoHome(sdk: sdk),
      ),
    );
  }
}

class DemoHome extends StatefulWidget {
  final EixamConnectSdk sdk;

  const DemoHome({super.key, required this.sdk});

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  late final SosController controller;
  late final TrackingController trackingController;
  late final DeathManController deathManController;
  late final ContactsController contactsController;
  late final DeviceController deviceController;
  PermissionState _permissionState = const PermissionState();

  @override
  void initState() {
    super.initState();
    controller = SosController(sdk: widget.sdk)..initialize();
    trackingController = TrackingController(sdk: widget.sdk)..initialize();
    deathManController = DeathManController(sdk: widget.sdk)..initialize();
    contactsController = ContactsController(sdk: widget.sdk)..initialize();
    deviceController = DeviceController(sdk: widget.sdk)..initialize();
    _loadPermissionState();
  }

  Future<void> _loadPermissionState() async {
    final permissions = await widget.sdk.getPermissionState();
    if (!mounted) return;
    setState(() => _permissionState = permissions);
  }

  Future<void> _requestLocationPermission() async {
    final permissions = await widget.sdk.requestLocationPermission();
    if (!mounted) return;
    setState(() => _permissionState = permissions);
  }

  Future<void> _requestNotificationPermission() async {
    await widget.sdk.initializeNotifications();
    final permissions = await widget.sdk.requestNotificationPermission();
    if (!mounted) return;
    setState(() => _permissionState = permissions);
  }

  Future<void> _requestBluetoothPermission() async {
    final permissions = await widget.sdk.requestBluetoothPermission();
    if (!mounted) return;
    setState(() => _permissionState = permissions);
  }

  Future<void> _showTestNotification() async {
    await widget.sdk.showLocalNotification(
      title: 'EIXAM test',
      body: 'SDK local notification test',
    );
  }

  Future<void> _startTracking() async {
    try {
      await trackingController.start();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  Future<void> _stopTracking() async {
    await trackingController.stop();
    if (mounted) setState(() {});
  }

  Future<void> _scheduleDeathManQuickDemo() async {
    await deathManController.schedule(
      expectedReturnAt: DateTime.now().add(const Duration(seconds: 20)),
      gracePeriod: const Duration(seconds: 10),
      checkInWindow: const Duration(seconds: 15),
      autoTriggerSos: true,
    );
  }

  @override
  void dispose() {
    contactsController.dispose();
    deathManController.dispose();
    trackingController.dispose();
    deviceController.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('EIXAM Control App · SDK Demo')),
      body: AnimatedBuilder(
        animation: Listenable.merge([controller, trackingController, deathManController, contactsController, deviceController]),
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              _PermissionCard(
                permissionState: _permissionState,
                onRequestLocation: _requestLocationPermission,
                onRequestNotifications: _requestNotificationPermission,
                onRequestBluetooth: _requestBluetoothPermission,
                onShowTestNotification: _showTestNotification,
              ),
              const SizedBox(height: 16),
              _DeviceCard(controller: deviceController),
              const SizedBox(height: 16),
              _TrackingCard(
                trackingState: trackingController.state,
                isStale: trackingController.isStale,
                lastPosition: trackingController.lastPosition,
                trackingError: trackingController.lastError,
                onStartTracking: _startTracking,
                onStopTracking: _stopTracking,
              ),
              const SizedBox(height: 16),
              _DeathManCard(
                controller: deathManController,
                onQuickDemo: _scheduleDeathManQuickDemo,
              ),
              const SizedBox(height: 16),
              _ContactsCard(controller: contactsController),
              const SizedBox(height: 16),
              SosStatusBanner(state: controller.state),
              const SizedBox(height: 24),
              Center(
                child: SosButtonRoundLarge(
                  onPressed: controller.canTrigger ? () => controller.trigger(message: 'Manual trigger from demo app') : null,
                  loading: controller.isBusy,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.tonal(
                onPressed: controller.canCancel ? () => controller.cancel(reason: 'Cancelled from demo app') : null,
                child: const Text('Cancel SOS'),
              ),
              const SizedBox(height: 24),
              _InfoCard(title: 'Current state', child: Text(controller.state.name)),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Last incident',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(controller.lastIncident?.id ?? 'No incidents yet'),
                    if (controller.lastIncident?.positionSnapshot != null) ...[
                      const SizedBox(height: 8),
                      Text('Lat snapshot: ${controller.lastIncident!.positionSnapshot!.latitude.toStringAsFixed(6)}'),
                      Text('Lng snapshot: ${controller.lastIncident!.positionSnapshot!.longitude.toStringAsFixed(6)}'),
                      Text('Source: ${controller.lastIncident!.positionSnapshot!.source.name}'),
                    ],
                  ],
                ),
              ),
              if (controller.lastError != null) ...[
                const SizedBox(height: 12),
                _InfoCard(title: 'Last error', child: Text(controller.lastError!)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final DeviceController controller;

  const _DeviceCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    final status = controller.status;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Device module', style: Theme.of(context).textTheme.titleMedium)),
                FilledButton.tonal(
                  onPressed: controller.isBusy ? null : controller.refresh,
                  child: const Text('Refresh'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Device: ${status?.deviceAlias ?? status?.deviceId ?? 'No device'}'),
            if (status?.model != null) Text('Model: ${status!.model}'),
            Text('Paired: ${status?.paired == true ? 'Yes' : 'No'}'),
            Text('Activated: ${status?.activated == true ? 'Yes' : 'No'}'),
            Text('Connected: ${status?.connected == true ? 'Yes' : 'No'}'),
            Text('Ready for safety: ${status?.isReadyForSafety == true ? 'Yes' : 'No'}'),
            if (status?.batteryLevel != null) Text('Battery: ${status!.batteryLevel}%'),
            if (status?.signalQuality != null) Text('Signal quality: ${status!.signalQuality}/4'),
            if (status?.firmwareVersion != null) Text('Firmware: ${status!.firmwareVersion}'),
            if (status?.lastSyncedAt != null) Text('Last sync: ${status!.lastSyncedAt}'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: controller.isBusy ? null : () => controller.pair('PAIR-DEMO-001'),
                  child: const Text('Pair'),
                ),
                FilledButton.tonal(
                  onPressed: controller.isBusy ? null : () => controller.activate('ACT-DEMO-001'),
                  child: const Text('Activate'),
                ),
                FilledButton.tonal(
                  onPressed: controller.isBusy || !(status?.paired ?? false) ? null : controller.unpair,
                  child: const Text('Unpair'),
                ),
              ],
            ),
            if (controller.lastError != null) ...[
              const SizedBox(height: 12),
              Text(controller.lastError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ContactsCard extends StatelessWidget {
  final ContactsController controller;

  const _ContactsCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Emergency contacts', style: Theme.of(context).textTheme.titleMedium)),
                FilledButton.tonal(
                  onPressed: controller.isBusy
                      ? null
                      : () => controller.add(
                            name: 'Mountain Rescue',
                            phone: '+34 600 123 123',
                            email: 'rescue@eixam.test',
                            priority: 1,
                          ),
                  child: const Text('Add sample'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (controller.contacts.isEmpty)
              const Text('No emergency contacts configured yet.')
            else
              ...controller.contacts.map((contact) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${contact.name} · P${contact.priority}'),
                    subtitle: Text(contact.phone ?? contact.email ?? 'No contact channel'),
                    leading: Switch(
                      value: contact.active,
                      onChanged: controller.isBusy ? null : (_) => controller.toggleActive(contact),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: controller.isBusy ? null : () => controller.remove(contact.id),
                    ),
                  )),
            if (controller.lastError != null) ...[
              const SizedBox(height: 8),
              Text(controller.lastError!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  final PermissionState permissionState;
  final Future<void> Function() onRequestLocation;
  final Future<void> Function() onRequestNotifications;
  final Future<void> Function() onRequestBluetooth;
  final Future<void> Function() onShowTestNotification;

  const _PermissionCard({
    required this.permissionState,
    required this.onRequestLocation,
    required this.onRequestNotifications,
    required this.onRequestBluetooth,
    required this.onShowTestNotification,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Permissions', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Location: ${permissionState.location.name}'),
            Text('Notifications: ${permissionState.notifications.name}'),
            Text('Bluetooth: ${permissionState.bluetooth.name}'),
            Text('Bluetooth enabled: ${permissionState.bluetoothEnabled ? 'Yes' : 'No'}'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: onRequestLocation,
                  child: const Text('Request location permission'),
                ),
                FilledButton.tonal(
                  onPressed: onRequestNotifications,
                  child: const Text('Request notification permission'),
                ),
                FilledButton.tonal(
                  onPressed: onRequestBluetooth,
                  child: const Text('Request Bluetooth permission'),
                ),
                OutlinedButton(
                  onPressed: permissionState.hasNotificationAccess ? onShowTestNotification : null,
                  child: const Text('Test local notification'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackingCard extends StatelessWidget {
  final TrackingState trackingState;
  final bool isStale;
  final TrackingPosition? lastPosition;
  final String? trackingError;
  final Future<void> Function() onStartTracking;
  final Future<void> Function() onStopTracking;

  const _TrackingCard({
    required this.trackingState,
    required this.isStale,
    required this.lastPosition,
    required this.trackingError,
    required this.onStartTracking,
    required this.onStopTracking,
  });

  @override
  Widget build(BuildContext context) {
    final started = trackingState == TrackingState.starting ||
        trackingState == TrackingState.tracking ||
        trackingState == TrackingState.stale;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tracking real', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('State: ${trackingState.name}${isStale ? ' (stale)' : ''}'),
            if (lastPosition != null) ...[
              const SizedBox(height: 8),
              Text('Lat: ${lastPosition!.latitude.toStringAsFixed(6)}'),
              Text('Lng: ${lastPosition!.longitude.toStringAsFixed(6)}'),
              Text('Accuracy: ${lastPosition!.accuracy?.toStringAsFixed(1) ?? '-'} m'),
              Text('Timestamp: ${lastPosition!.timestamp.toIso8601String()}'),
            ],
            if (trackingError != null) ...[
              const SizedBox(height: 8),
              Text(trackingError!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: started ? null : onStartTracking,
                  child: const Text('Start tracking'),
                ),
                FilledButton.tonal(
                  onPressed: started ? onStopTracking : null,
                  child: const Text('Stop tracking'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DeathManCard extends StatelessWidget {
  final DeathManController controller;
  final Future<void> Function() onQuickDemo;

  const _DeathManCard({required this.controller, required this.onQuickDemo});

  String _formatDuration(Duration? duration) {
    if (duration == null) return '-';
    final seconds = duration.inSeconds;
    final sign = seconds < 0 ? '-' : '';
    final abs = seconds.abs();
    final mm = (abs ~/ 60).toString().padLeft(2, '0');
    final ss = (abs % 60).toString().padLeft(2, '0');
    return '$sign$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final plan = controller.activePlan;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Death Man Protocol', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Estado: ${controller.status?.name ?? 'sin_plan'}'),
            Text('Tiempo restante: ${_formatDuration(controller.timeRemaining)}'),
            if (plan != null) ...[
              const SizedBox(height: 8),
              Text('Retorno previsto: ${plan.expectedReturnAt.toIso8601String()}'),
              Text('Grace: ${plan.gracePeriod.inSeconds}s · Check-in: ${plan.checkInWindow.inSeconds}s'),
              Text('Auto SOS: ${plan.autoTriggerSos ? 'sí' : 'no'}'),
            ],
            if (controller.lastError != null) ...[
              const SizedBox(height: 8),
              Text(controller.lastError!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: controller.hasActivePlan ? null : onQuickDemo,
                  child: const Text('Quick demo (20s)'),
                ),
                FilledButton.tonal(
                  onPressed: controller.hasActivePlan ? controller.confirmCheckIn : null,
                  child: const Text('Confirmar que estoy bien'),
                ),
                OutlinedButton(
                  onPressed: controller.hasActivePlan ? controller.cancelPlan : null,
                  child: const Text('Cancelar plan'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _InfoCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
