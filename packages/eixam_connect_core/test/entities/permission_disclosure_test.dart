import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('EixamPermissionDisclosureConfig', () {
    test('background location copy includes compliance phrases', () {
      const texts = EixamPermissionDisclosureConfig.defaultLocationBackground;

      expect(texts.title, contains('background location'));
      expect(texts.body.toLowerCase(), contains('location'));
      expect(texts.body.toLowerCase(), contains('app is closed or not in use'));
      expect(texts.body, contains('SOS'));
      expect(texts.body, contains('protection mode'));
      expect(texts.body, contains('safety tracking'));
      expect(texts.body, contains('connected TAG monitoring'));
    });

    test('host override replaces only configured texts', () {
      const config = EixamPermissionDisclosureConfig(
        locationForeground: EixamPermissionDisclosureTexts(
          title: 'Custom location title',
          body: 'Custom location body',
          primaryActionLabel: 'Agree',
          secondaryActionLabel: 'Later',
        ),
      );

      expect(
        config.textsFor(EixamPermissionPurpose.locationForeground).title,
        'Custom location title',
      );
      expect(
        config.textsFor(EixamPermissionPurpose.nearbyDevicesBluetooth).title,
        EixamPermissionDisclosureConfig.defaultNearbyDevicesBluetooth.title,
      );
    });
  });
}
