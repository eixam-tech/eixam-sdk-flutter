/// Host apps should provide a fully signed SDK identity payload obtained from
/// their own backend/partner backend.
typedef EixamSignedSessionProvider = Future<EixamSession> Function();

class EixamSession {
  final String appId;
  final String externalUserId;
  final String userHash;
  final String? sdkUserId;
  final String? canonicalExternalUserId;
  final String? refreshToken;

  const EixamSession({
    required this.appId,
    required this.externalUserId,
    required this.userHash,
    this.sdkUserId,
    this.canonicalExternalUserId,
    this.refreshToken,
  });

  /// Explicit helper for the confirmed partner-backend integration pattern.
  ///
  /// The mobile SDK consumes the signed identity payload and must not call the
  /// partner signing endpoint or compute the hash locally.
  const EixamSession.signed({
    required String appId,
    required String externalUserId,
    required String userHash,
    String? sdkUserId,
    String? canonicalExternalUserId,
    String? refreshToken,
  }) : this(
          appId: appId,
          externalUserId: externalUserId,
          userHash: userHash,
          sdkUserId: sdkUserId,
          canonicalExternalUserId: canonicalExternalUserId,
          refreshToken: refreshToken,
        );

  @Deprecated('Use userHash instead.')
  String get accessToken => userHash;

  @Deprecated('Use externalUserId instead.')
  String get userId => externalUserId;

  EixamSession copyWith({
    String? appId,
    String? externalUserId,
    String? userHash,
    Object? sdkUserId = _unset,
    Object? canonicalExternalUserId = _unset,
    Object? refreshToken = _unset,
  }) {
    return EixamSession(
      appId: appId ?? this.appId,
      externalUserId: externalUserId ?? this.externalUserId,
      userHash: userHash ?? this.userHash,
      sdkUserId:
          identical(sdkUserId, _unset) ? this.sdkUserId : sdkUserId as String?,
      canonicalExternalUserId: identical(canonicalExternalUserId, _unset)
          ? this.canonicalExternalUserId
          : canonicalExternalUserId as String?,
      refreshToken: identical(refreshToken, _unset)
          ? this.refreshToken
          : refreshToken as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'appId': appId,
      'externalUserId': externalUserId,
      'userHash': userHash,
      'sdkUserId': sdkUserId,
      'canonicalExternalUserId': canonicalExternalUserId,
      'refreshToken': refreshToken,
    };
  }

  factory EixamSession.fromJson(Map<String, dynamic> json) {
    return EixamSession(
      appId: json['appId'] as String,
      externalUserId: json['externalUserId'] as String,
      userHash: json['userHash'] as String,
      sdkUserId: json['sdkUserId'] as String?,
      canonicalExternalUserId: json['canonicalExternalUserId'] as String?,
      refreshToken: json['refreshToken'] as String?,
    );
  }

  static const Object _unset = Object();
}
