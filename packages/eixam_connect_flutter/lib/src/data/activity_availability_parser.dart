import 'package:eixam_connect_core/eixam_connect_core.dart';

/// GET /v1/sdk/activities response shape. Deliberately independent of the
/// ActivitySession key grammar. Unknown properties are ignored; duplicates stay.
List<SdkAvailableActivity> parseAvailableActivities(Object? payload) {
  if (payload is! Map<String, dynamic> || payload['activities'] is! List) {
    throw const FormatException('Expected an activities array.');
  }
  return (payload['activities'] as List)
      .map((Object? item) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Expected an activity object.');
        }
        final id = item['id'];
        final key = item['key'];
        if (id is! String ||
            !_uuid.hasMatch(id) ||
            id.length != 36 ||
            key is! String ||
            key.isEmpty ||
            key.length > 50 ||
            _key.matchAsPrefix(key)?.end != key.length) {
          throw const FormatException('Invalid activity id/key.');
        }
        return SdkAvailableActivity(id: id, key: key);
      })
      .toList(growable: false);
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _key = RegExp(r'^[a-z0-9_-]+$');
