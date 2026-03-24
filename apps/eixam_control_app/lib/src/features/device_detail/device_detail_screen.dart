import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../technical_lab/technical_lab_screen.dart';

class DeviceDetailScreen extends TechnicalLabScreen {
  DeviceDetailScreen({
    super.key,
    required EixamConnectSdk sdk,
    String? notificationContextMessage,
    String? notificationActionId,
    int? notificationNodeId,
  }) : super(
          sdk: sdk,
          notificationRequest: notificationContextMessage == null &&
                  notificationActionId == null &&
                  notificationNodeId == null
              ? null
              : BleNotificationNavigationRequest(
                  actionId: notificationActionId ?? 'legacy',
                  reason: notificationContextMessage ??
                      'Opened from notification context',
                  state: DeviceSosState.unknown,
                  nodeId: notificationNodeId,
                ),
        );
}
