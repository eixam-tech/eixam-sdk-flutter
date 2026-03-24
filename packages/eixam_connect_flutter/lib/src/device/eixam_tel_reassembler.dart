import 'eixam_tel_fragment.dart';

class EixamTelReassembler {
  int? _activeTotalLength;
  final Map<int, List<int>> _fragmentsByOffset = <int, List<int>>{};

  List<int>? addFragment(EixamTelFragment fragment) {
    if (fragment.offset < 0) {
      reset();
      return null;
    }

    final activeTotalLength = _activeTotalLength;
    if (activeTotalLength == null) {
      _activeTotalLength = fragment.totalLength;
    } else if (activeTotalLength != fragment.totalLength) {
      reset();
      _activeTotalLength = fragment.totalLength;
    }

    final fragmentEnd = fragment.offset + fragment.fragmentLength;
    if (fragmentEnd > fragment.totalLength) {
      reset();
      return null;
    }

    for (final entry in _fragmentsByOffset.entries) {
      final existingStart = entry.key;
      final existingEnd = existingStart + entry.value.length;
      final overlaps =
          fragment.offset < existingEnd && fragmentEnd > existingStart;
      if (!overlaps) {
        continue;
      }
      final sameRange = existingStart == fragment.offset &&
          existingEnd == fragmentEnd &&
          _listEquals(entry.value, fragment.fragmentPayload);
      if (sameRange) {
        return _tryComplete(fragment.totalLength);
      }
      reset();
      return null;
    }

    _fragmentsByOffset[fragment.offset] = fragment.fragmentPayload;
    return _tryComplete(fragment.totalLength);
  }

  void reset() {
    _activeTotalLength = null;
    _fragmentsByOffset.clear();
  }

  List<int>? _tryComplete(int totalLength) {
    if (_fragmentsByOffset.isEmpty) {
      return null;
    }

    final orderedOffsets = _fragmentsByOffset.keys.toList()..sort();
    var cursor = 0;
    final completed = <int>[];
    for (final offset in orderedOffsets) {
      if (offset != cursor) {
        return null;
      }
      final payload = _fragmentsByOffset[offset]!;
      completed.addAll(payload);
      cursor += payload.length;
    }

    if (cursor != totalLength) {
      return null;
    }

    final blob = List<int>.unmodifiable(completed);
    reset();
    return blob;
  }

  bool _listEquals(List<int> left, List<int> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }
}
