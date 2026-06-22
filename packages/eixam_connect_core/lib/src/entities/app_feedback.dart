final class AppFeedbackSubmission {

  factory AppFeedbackSubmission.fromJson(Map<String, dynamic> json) {
    final issue = json['issue'];
    if (issue is! Map<String, dynamic>) {
      throw const FormatException('E_SDK_FEEDBACK_MISSING_ISSUE');
    }
    return AppFeedbackSubmission(
      issue: AppFeedbackIssue.fromJson(issue),
    );
  }
  const AppFeedbackSubmission({required this.issue});

  final AppFeedbackIssue issue;

  String get identifier => issue.identifier;

  String get url => issue.url;
}

final class AppFeedbackIssue {

  factory AppFeedbackIssue.fromJson(Map<String, dynamic> json) {
    final id = _readRequiredString(json, 'id');
    final identifier = _readRequiredString(json, 'identifier');
    final title = _readString(json, 'title') ?? '';
    final url = _readString(json, 'url') ?? '';
    final createdAt = DateTime.tryParse(_readString(json, 'created_at') ?? '');
    return AppFeedbackIssue(
      id: id,
      identifier: identifier,
      title: title,
      url: url,
      createdAt: createdAt,
    );
  }
  const AppFeedbackIssue({
    required this.id,
    required this.identifier,
    required this.title,
    required this.url,
    required this.createdAt,
  });

  final String id;
  final String identifier;
  final String title;
  final String url;
  final DateTime? createdAt;

  static String _readRequiredString(Map<String, dynamic> json, String key) {
    final value = _readString(json, key);
    if (value == null || value.isEmpty) {
      throw FormatException('E_SDK_FEEDBACK_MISSING_$key');
    }
    return value;
  }

  static String? _readString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
