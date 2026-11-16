import 'tag_alert.dart';

final class TagAlertText {
  const TagAlertText({required this.title, required this.body});

  final String title;
  final String body;
}

/// Hosts localize TAG alert wording with this callback. It must be pure and
/// fast, and must not promise guaranteed delivery or rescue.
typedef TagAlertTextResolver = TagAlertText Function(TagAlert alert);

/// Neutral English fallback used when the host supplies no resolver. It omits
/// coordinates on purpose: notifications can show on a locked screen.
TagAlertText defaultTagAlertText(TagAlert alert) {
  final alias = alert.deviceAlias?.trim();
  final name = alias == null || alias.isEmpty ? 'Your TAG' : alias;
  switch (alert.kind) {
    case TagAlertKind.batteryLow:
      final threshold =
          alert.batteryThreshold == TagAlertBatteryThreshold.below10
          ? '10'
          : '30';
      return TagAlertText(
        title: 'TAG battery low',
        body: '$name battery is below $threshold %.',
      );
    case TagAlertKind.tagDisconnected:
      final minutes = alert.elapsed!.inMinutes;
      return TagAlertText(
        title: 'TAG disconnected',
        body: '$name has been disconnected for more than $minutes min.',
      );
    case TagAlertKind.bluetoothOff:
      return const TagAlertText(
        title: 'Bluetooth is off',
        body: 'Turn Bluetooth on to keep your TAG connected.',
      );
  }
}
