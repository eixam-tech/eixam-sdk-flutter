import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/material.dart';

class LabCard extends StatelessWidget {
  const LabCard({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class LabInfoLine extends StatelessWidget {
  const LabInfoLine({
    super.key,
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

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.active,
  });

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      backgroundColor: active
          ? Colors.green.withValues(alpha: 0.14)
          : Colors.black.withValues(alpha: 0.06),
    );
  }
}

class PermissionsSection extends StatelessWidget {
  const PermissionsSection({
    super.key,
    required this.permissionState,
    required this.loading,
    required this.onRefresh,
    required this.onRequestBluetooth,
    required this.onRequestNotifications,
  });

  final PermissionState? permissionState;
  final bool loading;
  final VoidCallback onRefresh;
  final VoidCallback onRequestBluetooth;
  final VoidCallback onRequestNotifications;

  @override
  Widget build(BuildContext context) {
    return LabCard(
      title: 'Permissions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LabInfoLine(
            label: 'Location',
            value: permissionState?.location.toString() ?? 'Unknown',
          ),
          LabInfoLine(
            label: 'Notifications',
            value: permissionState?.notifications.toString() ?? 'Unknown',
          ),
          LabInfoLine(
            label: 'Bluetooth',
            value: permissionState?.bluetooth.toString() ?? 'Unknown',
          ),
          LabInfoLine(
            label: 'Bluetooth enabled',
            value: permissionState?.bluetoothEnabled.toString() ?? 'Unknown',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: loading ? null : onRefresh,
                child: const Text('Refresh'),
              ),
              ElevatedButton(
                onPressed: loading ? null : onRequestBluetooth,
                child: const Text('Request Bluetooth'),
              ),
              ElevatedButton(
                onPressed: loading ? null : onRequestNotifications,
                child: const Text('Request notifications'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class NotificationsSection extends StatelessWidget {
  const NotificationsSection({
    super.key,
    required this.loading,
    required this.onInitialize,
    required this.onTest,
  });

  final bool loading;
  final VoidCallback onInitialize;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    return LabCard(
      title: 'Notifications',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Initialize local notifications and verify SDK-driven host alerts.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: loading ? null : onInitialize,
                child: const Text('Init notifications'),
              ),
              ElevatedButton(
                onPressed: loading ? null : onTest,
                child: const Text('Test notification'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ScanResultCard extends StatelessWidget {
  const ScanResultCard({
    super.key,
    required this.title,
    required this.scan,
    required this.isSelected,
    required this.services,
    required this.onTap,
  });

  final String title;
  final BleScanResult scan;
  final bool isSelected;
  final String? services;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected
          ? Colors.blue.withValues(alpha: 0.06)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected
                  ? Colors.blue
                  : Colors.black.withValues(alpha: 0.12),
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (isSelected) const Chip(label: Text('Selected')),
                ],
              ),
              const SizedBox(height: 6),
              Text('Device ID: ${scan.deviceId}'),
              Text('RSSI: ${scan.rssi}'),
              Text('Connectable: ${scan.connectable ? "Yes" : "No"}'),
              if (services != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Advertised services: $services',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

