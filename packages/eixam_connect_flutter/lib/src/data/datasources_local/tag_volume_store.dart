import 'shared_prefs_sdk_store.dart';

/// The buzzer volumes last written to one TAG (0–100 %). Either may be
/// unknown when only the other setter was ever used.
final class TagVolumes {
  const TagVolumes({this.notification, this.sos});

  final int? notification;
  final int? sos;

  bool get isEmpty => notification == null && sos == null;
}

/// TAG firmware keeps the buzzer volumes in RAM only (50 % after every
/// reboot), so the SDK remembers what it wrote, per TAG, to re-send it when
/// the TAG reconnects.
///
/// A TAG is known by several keys (canonical hardware id, node id, transport
/// id) and not all are known at every moment; values are written under every
/// known key, and a read returns, per volume, the newest value across keys.
abstract interface class TagVolumeStore {
  Future<TagVolumes?> read(Iterable<String> deviceKeys);

  Future<void> write(
    Iterable<String> deviceKeys, {
    int? notification,
    int? sos,
  });
}

final class SharedPrefsTagVolumeStore implements TagVolumeStore {
  SharedPrefsTagVolumeStore(this._store, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final SharedPrefsSdkStore _store;
  final DateTime Function() _clock;

  @override
  Future<TagVolumes?> read(Iterable<String> deviceKeys) async {
    final all = await _store.readJson(SharedPrefsSdkStore.tagVolumesKey);
    if (all == null) return null;
    final entries = <Map<dynamic, dynamic>>[
      for (final key in _normalized(deviceKeys))
        if (all[key] case final Map<dynamic, dynamic> entry) entry,
    ];
    final volumes = TagVolumes(
      notification: _newest(entries, 'notification'),
      sos: _newest(entries, 'sos'),
    );
    return volumes.isEmpty ? null : volumes;
  }

  /// The [field] value written last across the TAG's keys (an alias not
  /// known at the last write keeps an older value).
  static int? _newest(List<Map<dynamic, dynamic>> entries, String field) {
    int? value;
    var newestAt = -1;
    for (final entry in entries) {
      final candidate = _volume(entry[field]);
      final at = entry['${field}At'];
      final atMs = at is int ? at : 0;
      if (candidate != null && atMs > newestAt) {
        value = candidate;
        newestAt = atMs;
      }
    }
    return value;
  }

  @override
  Future<void> write(
    Iterable<String> deviceKeys, {
    int? notification,
    int? sos,
  }) async {
    final keys = _normalized(deviceKeys);
    if (keys.isEmpty || (notification == null && sos == null)) return;
    final all = Map<String, dynamic>.of(
      await _store.readJson(SharedPrefsSdkStore.tagVolumesKey) ??
          const <String, dynamic>{},
    );
    final atMs = _clock().toUtc().millisecondsSinceEpoch;
    for (final key in keys) {
      final previous = all[key];
      final entry = previous is Map
          ? Map<String, dynamic>.of(previous.cast<String, dynamic>())
          : <String, dynamic>{};
      if (notification != null) {
        entry['notification'] = notification;
        entry['notificationAt'] = atMs;
      }
      if (sos != null) {
        entry['sos'] = sos;
        entry['sosAt'] = atMs;
      }
      all[key] = entry;
    }
    await _store.saveJson(SharedPrefsSdkStore.tagVolumesKey, all);
  }

  static List<String> _normalized(Iterable<String> keys) => <String>{
    for (final key in keys)
      if (key.trim().isNotEmpty) key.trim().toLowerCase(),
  }.toList(growable: false);

  static int? _volume(Object? value) =>
      value is int && value >= 0 && value <= 100 ? value : null;
}
