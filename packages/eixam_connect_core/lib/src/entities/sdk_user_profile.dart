/// SDK user profile returned by `GET /v1/sdk/me` (`SDKMeResponse.user`).
///
/// Fields mirror the public OpenAPI schema; empty strings mean “not set”.
final class SdkUserProfile {
  const SdkUserProfile({
    required this.id,
    required this.appId,
    required this.externalUserId,
    required this.name,
    required this.email,
    required this.phone,
    required this.address,
  });

  final String id;
  final String appId;
  final String externalUserId;
  final String name;
  final String email;
  final String phone;
  final String address;

  factory SdkUserProfile.fromMeResponseJson(Map<String, dynamic> json) {
    final user = json['user'];
    if (user is! Map<String, dynamic>) {
      throw const FormatException('SDKMeResponse missing user object');
    }
    final id = user['id'];
    final appId = user['app_id'];
    final externalUserId = user['external_user_id'];
    if (id is! String ||
        id.trim().isEmpty ||
        appId is! String ||
        appId.trim().isEmpty ||
        externalUserId is! String ||
        externalUserId.trim().isEmpty) {
      throw const FormatException('SDK user payload missing required ids');
    }
    String str(dynamic v) => v is String ? v : '';
    return SdkUserProfile(
      id: id.trim(),
      appId: appId.trim(),
      externalUserId: externalUserId.trim(),
      name: str(user['name']).trim(),
      email: str(user['email']).trim(),
      phone: str(user['phone']).trim(),
      address: str(user['address']).trim(),
    );
  }

  /// Splits [name] into first / last segments for UI that uses separate fields.
  (String firstName, String lastName) splitDisplayNameForUi() {
    final n = name.trim();
    if (n.isEmpty) {
      return ('', '');
    }
    final space = n.indexOf(RegExp(r'\s'));
    if (space < 0) {
      return (n, '');
    }
    return (n.substring(0, space).trim(), n.substring(space + 1).trim());
  }

  /// Builds API `name` from onboarding-style first + last names.
  static String composeDisplayName(String firstName, String lastName) {
    final parts = [firstName.trim(), lastName.trim()]
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    return parts.join(' ');
  }
}

/// Partial update body for `PUT /v1/sdk/me` (`SDKUpdateMeRequest`).
///
/// `null` means omit the JSON key (leave unchanged). A non-null [String]
/// value is sent as-is; use `''` to clear per API semantics.
final class SdkUserProfileUpdate {
  const SdkUserProfileUpdate({
    this.name,
    this.email,
    this.phone,
    this.address,
  });

  final String? name;
  final String? email;
  final String? phone;
  final String? address;

  Map<String, dynamic> toRequestJson() {
    final m = <String, dynamic>{};
    if (name != null) {
      m['name'] = name;
    }
    if (email != null) {
      m['email'] = email;
    }
    if (phone != null) {
      m['phone'] = phone;
    }
    if (address != null) {
      m['address'] = address;
    }
    return m;
  }

  /// Sends every field so the backend replaces stored profile values from this payload.
  factory SdkUserProfileUpdate.full({
    required String name,
    required String email,
    required String phone,
    required String address,
  }) {
    return SdkUserProfileUpdate(
      name: name,
      email: email,
      phone: phone,
      address: address,
    );
  }
}
