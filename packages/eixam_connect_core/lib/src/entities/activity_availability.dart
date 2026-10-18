/// An activity configured for the authenticated SDK app by the backend.
/// Keys are preserved exactly; availability does not imply host/session support.
final class SdkAvailableActivity {
  const SdkAvailableActivity({required this.id, required this.key});

  /// Stable backend UUID, including across key renames.
  final String id;
  final String key;
}

/// Complete assignment snapshot in backend array order, including confirmed empty.
final class SdkActivityAvailability {
  SdkActivityAvailability({
    required List<SdkAvailableActivity> activities,
    required DateTime fetchedAt,
    required this.fromCache,
  }) : activities = List.unmodifiable(activities),
       fetchedAt = fetchedAt.toUtc();

  final List<SdkAvailableActivity> activities;
  final DateTime fetchedAt;

  /// True for restored/cached values. No TTL or freshness guarantee is implied.
  final bool fromCache;
}
