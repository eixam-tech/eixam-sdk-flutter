import '../entities/sdk_user_profile.dart';

/// Documented constraints for `PUT /v1/sdk/me` (`SDKUpdateMeRequest`).
abstract final class SdkProfileConstraints {
  static const int nameMaxLength = 120;
  static const int emailMaxLength = 254;
  static const int addressMaxLength = 255;

  /// When non-empty, must satisfy OpenAPI `format: email` / route description.
  static final RegExp emailPattern = RegExp(r'^[^@]+@[^@]+\.[^@]+$');

  /// Strict E.164 when non-empty (`^\+[1-9]\d{7,14}$`).
  static final RegExp phoneE164Pattern = RegExp(r'^\+[1-9]\d{7,14}$');
}

/// Fields exposed by `SDKUpdateMeRequest` for client-side validation UX.
enum SdkProfileFieldKey { name, email, phone, address }

/// Backend hint tying a validation message to a profile field when inferable.
final class SdkProfileApiFieldHint {
  const SdkProfileApiFieldHint({
    required this.field,
    required this.message,
  });

  final SdkProfileFieldKey field;
  final String message;
}

/// Client-side validation outcome before calling `PUT /v1/sdk/me`.
final class SdkProfileClientValidationIssue {
  const SdkProfileClientValidationIssue(this.field, this.kind);

  final SdkProfileFieldKey field;
  final SdkProfileValidationKind kind;
}

enum SdkProfileValidationKind {
  nameRequired,
  nameTooLong,
  emailTooLong,
  emailInvalidFormat,
  phoneInvalidE164,
  addressTooLong,
}

/// Validates profile fields per staging OpenAPI (`SDKUpdateMeRequest` + route text).
abstract final class SdkProfileValidators {
  static List<SdkProfileClientValidationIssue> validateFullPayload({
    required String displayName,
    required String email,
    required String phone,
    required String address,
    required bool requireNonEmptyName,
  }) {
    final issues = <SdkProfileClientValidationIssue>[];

    final nameTrim = displayName.trim();
    if (requireNonEmptyName && nameTrim.isEmpty) {
      issues.add(
        const SdkProfileClientValidationIssue(
          SdkProfileFieldKey.name,
          SdkProfileValidationKind.nameRequired,
        ),
      );
    } else if (nameTrim.length > SdkProfileConstraints.nameMaxLength) {
      issues.add(
        const SdkProfileClientValidationIssue(
          SdkProfileFieldKey.name,
          SdkProfileValidationKind.nameTooLong,
        ),
      );
    }

    final emailTrim = email.trim();
    if (emailTrim.length > SdkProfileConstraints.emailMaxLength) {
      issues.add(
        const SdkProfileClientValidationIssue(
          SdkProfileFieldKey.email,
          SdkProfileValidationKind.emailTooLong,
        ),
      );
    } else if (emailTrim.isNotEmpty &&
        !SdkProfileConstraints.emailPattern.hasMatch(emailTrim)) {
      issues.add(
        const SdkProfileClientValidationIssue(
          SdkProfileFieldKey.email,
          SdkProfileValidationKind.emailInvalidFormat,
        ),
      );
    }

    final phoneTrim = phone.trim();
    if (phoneTrim.isNotEmpty &&
        !SdkProfileConstraints.phoneE164Pattern.hasMatch(phoneTrim)) {
      issues.add(
        const SdkProfileClientValidationIssue(
          SdkProfileFieldKey.phone,
          SdkProfileValidationKind.phoneInvalidE164,
        ),
      );
    }

    if (address.trim().length > SdkProfileConstraints.addressMaxLength) {
      issues.add(
        const SdkProfileClientValidationIssue(
          SdkProfileFieldKey.address,
          SdkProfileValidationKind.addressTooLong,
        ),
      );
    }

    return issues;
  }

  /// Convenience for onboarding/UI that collects separate first + last names.
  ///
  /// When [requireNonEmptyNameParts] is true, both names must be non-empty
  /// before format constraints are evaluated on the composed display name.
  static List<SdkProfileClientValidationIssue> validateFromUiFields({
    required String firstName,
    required String lastName,
    required String email,
    required String phone,
    required String address,
    required bool requireNonEmptyNameParts,
  }) {
    final issues = <SdkProfileClientValidationIssue>[];
    final first = firstName.trim();
    final last = lastName.trim();
    if (requireNonEmptyNameParts && (first.isEmpty || last.isEmpty)) {
      issues.add(
        const SdkProfileClientValidationIssue(
          SdkProfileFieldKey.name,
          SdkProfileValidationKind.nameRequired,
        ),
      );
    }
    final displayName = SdkUserProfile.composeDisplayName(firstName, lastName);
    issues.addAll(
      validateFullPayload(
        displayName: displayName,
        email: email,
        phone: phone,
        address: address,
        requireNonEmptyName: false,
      ),
    );
    return issues;
  }
}
