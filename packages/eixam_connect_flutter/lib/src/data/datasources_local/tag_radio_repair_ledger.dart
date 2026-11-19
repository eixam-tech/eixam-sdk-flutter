import 'shared_prefs_sdk_store.dart';

enum TagRadioRepairState { awaitingVerification, blocked }

final class TagRadioRepairMark {
  const TagRadioRepairMark(this.state, this.at);

  final TagRadioRepairState state;
  final DateTime at;
}

/// Per-TAG radio repair bookkeeping that survives an app restart, so a TAG
/// that never takes the config is not rebooted again on every app launch.
/// A TAG is known by several keys; a mark is written under every known key
/// and the newest mark across the keys wins.
abstract interface class TagRadioRepairLedger {
  Future<TagRadioRepairMark?> read(Iterable<String> deviceKeys);

  /// [mark] null clears the TAG's mark.
  Future<void> write(Iterable<String> deviceKeys, TagRadioRepairMark? mark);
}

final class InMemoryTagRadioRepairLedger implements TagRadioRepairLedger {
  final Map<String, TagRadioRepairMark> _marks = <String, TagRadioRepairMark>{};

  @override
  Future<TagRadioRepairMark?> read(Iterable<String> deviceKeys) async =>
      _newest(<TagRadioRepairMark?>[for (final k in deviceKeys) _marks[k]]);

  @override
  Future<void> write(
    Iterable<String> deviceKeys,
    TagRadioRepairMark? mark,
  ) async {
    for (final key in deviceKeys) {
      if (mark == null) {
        _marks.remove(key);
      } else {
        _marks[key] = mark;
      }
    }
  }
}

final class SharedPrefsTagRadioRepairLedger implements TagRadioRepairLedger {
  SharedPrefsTagRadioRepairLedger(this._store);

  final SharedPrefsSdkStore _store;

  @override
  Future<TagRadioRepairMark?> read(Iterable<String> deviceKeys) async {
    final all = await _store.readJson(SharedPrefsSdkStore.tagRadioRepairKey);
    if (all == null) return null;
    return _newest(<TagRadioRepairMark?>[
      for (final key in _normalized(deviceKeys)) _decode(all[key]),
    ]);
  }

  @override
  Future<void> write(
    Iterable<String> deviceKeys,
    TagRadioRepairMark? mark,
  ) async {
    final keys = _normalized(deviceKeys);
    if (keys.isEmpty) return;
    final all = Map<String, dynamic>.of(
      await _store.readJson(SharedPrefsSdkStore.tagRadioRepairKey) ??
          const <String, dynamic>{},
    );
    for (final key in keys) {
      if (mark == null) {
        all.remove(key);
      } else {
        all[key] = <String, dynamic>{
          'state': mark.state.name,
          'at': mark.at.toUtc().millisecondsSinceEpoch,
        };
      }
    }
    await _store.saveJson(SharedPrefsSdkStore.tagRadioRepairKey, all);
  }

  static TagRadioRepairMark? _decode(Object? value) {
    if (value is! Map) return null;
    final at = value['at'];
    final state = TagRadioRepairState.values.where(
      (s) => s.name == value['state'],
    );
    if (at is! int || state.isEmpty) return null;
    return TagRadioRepairMark(
      state.first,
      DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
    );
  }

  static List<String> _normalized(Iterable<String> keys) => <String>{
    for (final key in keys)
      if (key.trim().isNotEmpty) key.trim().toLowerCase(),
  }.toList(growable: false);
}

TagRadioRepairMark? _newest(Iterable<TagRadioRepairMark?> marks) {
  TagRadioRepairMark? newest;
  for (final mark in marks) {
    if (mark != null && (newest == null || mark.at.isAfter(newest.at))) {
      newest = mark;
    }
  }
  return newest;
}
