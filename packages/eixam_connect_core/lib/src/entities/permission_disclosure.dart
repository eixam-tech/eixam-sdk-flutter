import '../enums/sdk_permission_status.dart';
import 'permission_state.dart';

enum EixamPermissionPurpose {
  locationForeground,
  locationBackground,
  nearbyDevicesBluetooth,
  notifications,
}

enum EixamPermissionNativeAction {
  none,
  requestLocationWhenInUse,
  requestBackgroundLocation,
  requestBluetoothNearbyDevices,
  requestNotifications,
  openAppSettings,
}

class EixamPermissionRequirement {
  const EixamPermissionRequirement({
    required this.purpose,
    this.nativeAction,
    this.featureKey,
  });

  const EixamPermissionRequirement.locationForeground({
    String? featureKey,
  }) : this(
          purpose: EixamPermissionPurpose.locationForeground,
          nativeAction: EixamPermissionNativeAction.requestLocationWhenInUse,
          featureKey: featureKey,
        );

  const EixamPermissionRequirement.locationBackground({
    String? featureKey,
  }) : this(
          purpose: EixamPermissionPurpose.locationBackground,
          nativeAction: EixamPermissionNativeAction.openAppSettings,
          featureKey: featureKey,
        );

  const EixamPermissionRequirement.nearbyDevicesBluetooth({
    String? featureKey,
  }) : this(
          purpose: EixamPermissionPurpose.nearbyDevicesBluetooth,
          nativeAction:
              EixamPermissionNativeAction.requestBluetoothNearbyDevices,
          featureKey: featureKey,
        );

  const EixamPermissionRequirement.notifications({
    String? featureKey,
  }) : this(
          purpose: EixamPermissionPurpose.notifications,
          nativeAction: EixamPermissionNativeAction.requestNotifications,
          featureKey: featureKey,
        );

  final EixamPermissionPurpose purpose;
  final EixamPermissionNativeAction? nativeAction;
  final String? featureKey;
}

class EixamPermissionDisclosureTexts {
  const EixamPermissionDisclosureTexts({
    required this.title,
    required this.body,
    required this.primaryActionLabel,
    required this.secondaryActionLabel,
    this.legalNote,
    this.limitedFeatureMessage,
  });

  final String title;
  final String body;
  final String primaryActionLabel;
  final String secondaryActionLabel;
  final String? legalNote;
  final String? limitedFeatureMessage;

  EixamPermissionDisclosureTexts copyWith({
    String? title,
    String? body,
    String? primaryActionLabel,
    String? secondaryActionLabel,
    String? legalNote,
    String? limitedFeatureMessage,
  }) {
    return EixamPermissionDisclosureTexts(
      title: title ?? this.title,
      body: body ?? this.body,
      primaryActionLabel: primaryActionLabel ?? this.primaryActionLabel,
      secondaryActionLabel: secondaryActionLabel ?? this.secondaryActionLabel,
      legalNote: legalNote ?? this.legalNote,
      limitedFeatureMessage:
          limitedFeatureMessage ?? this.limitedFeatureMessage,
    );
  }
}

class EixamPermissionDisclosureConfig {
  const EixamPermissionDisclosureConfig({
    this.locationForeground = defaultLocationForeground,
    this.locationBackground = defaultLocationBackground,
    this.nearbyDevicesBluetooth = defaultNearbyDevicesBluetooth,
    this.notifications = defaultNotifications,
  });

  static const defaultLocationForeground = EixamPermissionDisclosureTexts(
    title: 'Allow location for SOS',
    body: 'Eixam uses your location to send your position during an SOS and '
        'to show your safety status while you are using the app.',
    primaryActionLabel: 'Continue',
    secondaryActionLabel: 'Not now',
    limitedFeatureMessage:
        'SOS location and safety status are limited until location is allowed.',
  );

  static const defaultLocationBackground = EixamPermissionDisclosureTexts(
    title: 'Allow background location for protection',
    body: 'Eixam collects location data to enable SOS, protection mode, safety '
        'tracking, and connected TAG monitoring even when the app is closed or '
        'not in use. This helps send your last known position if you trigger '
        'an emergency.',
    primaryActionLabel: 'Continue',
    secondaryActionLabel: 'Not now',
    limitedFeatureMessage:
        'Protection mode and background safety tracking are limited until '
        'background location is allowed.',
  );

  static const defaultNearbyDevicesBluetooth = EixamPermissionDisclosureTexts(
    title: 'Connect your Eixam TAG',
    body: 'Eixam uses Bluetooth/Nearby Devices to find and connect to your '
        'TAG, keep its safety status updated, and allow the device button to '
        'trigger or cancel SOS.',
    primaryActionLabel: 'Continue',
    secondaryActionLabel: 'Not now',
    limitedFeatureMessage:
        'TAG pairing, device monitoring, and physical SOS controls are limited '
        'until Bluetooth/Nearby Devices access is allowed.',
  );

  static const defaultNotifications = EixamPermissionDisclosureTexts(
    title: 'Allow safety notifications',
    body: 'Eixam sends notifications for SOS status, device alerts, protection '
        'events, and important safety updates.',
    primaryActionLabel: 'Continue',
    secondaryActionLabel: 'Not now',
    limitedFeatureMessage:
        'Safety notifications are limited until notification permission is '
        'allowed.',
  );

  final EixamPermissionDisclosureTexts locationForeground;
  final EixamPermissionDisclosureTexts locationBackground;
  final EixamPermissionDisclosureTexts nearbyDevicesBluetooth;
  final EixamPermissionDisclosureTexts notifications;

  EixamPermissionDisclosureTexts textsFor(EixamPermissionPurpose purpose) {
    return switch (purpose) {
      EixamPermissionPurpose.locationForeground => locationForeground,
      EixamPermissionPurpose.locationBackground => locationBackground,
      EixamPermissionPurpose.nearbyDevicesBluetooth => nearbyDevicesBluetooth,
      EixamPermissionPurpose.notifications => notifications,
    };
  }
}

class EixamPermissionDisclosure {
  const EixamPermissionDisclosure({
    required this.purpose,
    required this.title,
    required this.body,
    required this.primaryActionLabel,
    required this.secondaryActionLabel,
    this.legalNote,
    this.visibleFeatures = const <String>[],
  });

  factory EixamPermissionDisclosure.fromTexts({
    required EixamPermissionPurpose purpose,
    required EixamPermissionDisclosureTexts texts,
    required List<String> visibleFeatures,
  }) {
    return EixamPermissionDisclosure(
      purpose: purpose,
      title: texts.title,
      body: texts.body,
      primaryActionLabel: texts.primaryActionLabel,
      secondaryActionLabel: texts.secondaryActionLabel,
      legalNote: texts.legalNote,
      visibleFeatures: visibleFeatures,
    );
  }

  final EixamPermissionPurpose purpose;
  final String title;
  final String body;
  final String primaryActionLabel;
  final String secondaryActionLabel;
  final String? legalNote;
  final List<String> visibleFeatures;
}

class EixamPermissionPreflightResult {
  const EixamPermissionPreflightResult({
    required this.requirement,
    required this.permissionState,
    required this.permissionStatus,
    required this.nativeAction,
    required this.nativePermissionAlreadySatisfied,
    required this.requiresDisclosure,
    required this.nativePromptAllowed,
    this.disclosure,
    this.limitedFeatureMessage,
  });

  final EixamPermissionRequirement requirement;
  final PermissionState permissionState;
  final SdkPermissionStatus permissionStatus;
  final EixamPermissionNativeAction nativeAction;
  final bool nativePermissionAlreadySatisfied;
  final bool requiresDisclosure;
  final bool nativePromptAllowed;
  final EixamPermissionDisclosure? disclosure;
  final String? limitedFeatureMessage;

  EixamPermissionPurpose get purpose => requirement.purpose;

  bool get userDeclinedDisclosure =>
      !nativePermissionAlreadySatisfied &&
      !requiresDisclosure &&
      !nativePromptAllowed;
}
