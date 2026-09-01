abstract final class EixamContactPhone {
  static String normalize(String phone) {
    final trimmed = phone.trim();
    if (trimmed.startsWith('+')) {
      return '+${trimmed.substring(1).replaceAll(RegExp(r'[^0-9]'), '')}';
    }
    return trimmed.replaceAll(RegExp(r'[\s-]'), '');
  }
}
