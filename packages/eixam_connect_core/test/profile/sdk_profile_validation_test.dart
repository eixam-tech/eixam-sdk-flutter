import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('SdkProfileValidators', () {
    test('accepts valid E.164 phone', () {
      final issues = SdkProfileValidators.validateFullPayload(
        displayName: 'Alice Example',
        email: '',
        phone: '+34911223344',
        address: '123 St',
        requireNonEmptyName: false,
      );
      expect(issues.where((i) => i.field == SdkProfileFieldKey.phone), isEmpty);
    });

    test('rejects invalid phone when non-empty', () {
      final issues = SdkProfileValidators.validateFullPayload(
        displayName: 'Alice Example',
        email: '',
        phone: '+34 911 22 33 44',
        address: '123 St',
        requireNonEmptyName: false,
      );
      expect(
        issues.any(
          (i) =>
              i.field == SdkProfileFieldKey.phone &&
              i.kind == SdkProfileValidationKind.phoneInvalidE164,
        ),
        isTrue,
      );
    });
  });
}
