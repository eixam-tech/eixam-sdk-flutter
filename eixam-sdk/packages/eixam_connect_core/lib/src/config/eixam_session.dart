class EixamSession {
  final String accessToken;
  final String? refreshToken;
  final String userId;

  const EixamSession({
    required this.accessToken,
    required this.userId,
    this.refreshToken,
  });
}
