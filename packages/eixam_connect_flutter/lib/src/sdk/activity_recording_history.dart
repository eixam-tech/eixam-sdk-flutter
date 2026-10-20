part of 'activity_recording_controller.dart';

extension _RecordingHistoryOperations on ActivityRecordingController {
  Future<SdkActivityRecordingHistoryPage> _listFinished({
    required int limit,
    String? cursor,
  }) async {
    RangeError.checkValueInInterval(limit, 1, 100, 'limit');
    return _command((generation) async {
      final scope = _owner!.scope;
      final tag = sha256
          .convert(utf8.encode('recording-history-v1:$scope'))
          .toString();
      final after = cursor == null
          ? null
          : _RecordingHistoryCursor.decode(cursor, tag);
      final records = await _transaction(generation, (tx) async {
        if (!_historyPrepared) await tx.prepareHistory(scope);
        return tx.finishedHistory(
          scope,
          limit: limit + 1,
          endedAtUs: after?.endedAtUs,
          recordingId: after?.recordingId,
        );
      });
      _checkGeneration(generation);
      _historyPrepared = true;
      final items = records.take(limit).map((r) => r.value).toList();
      final last = items.isEmpty ? null : items.last;
      return SdkActivityRecordingHistoryPage(
        items: items,
        nextCursor: records.length > limit
            ? _RecordingHistoryCursor(
                last!.endedAt!.microsecondsSinceEpoch,
                last.recordingId,
              ).encode(tag)
            : null,
      );
    }, restoreActive: false);
  }

  Future<void> _prepareOwner(int generation) async {
    if (_ownerPrepared) return;
    final conflict = await _transaction(
      generation,
      (tx) => tx.reconcileOwner(_owner!),
    );
    if (conflict) {
      _identityReady = false;
      throw _identityRequired;
    }
    _checkGeneration(generation);
    _ownerPrepared = true;
  }
}

final class _RecordingHistoryCursor {
  const _RecordingHistoryCursor(this.endedAtUs, this.recordingId);
  final int endedAtUs;
  final String recordingId;

  String encode(String ownerTag) => base64Url.encode(
    utf8.encode(jsonEncode([1, ownerTag, endedAtUs, recordingId])),
  );

  static _RecordingHistoryCursor decode(String token, String ownerTag) {
    try {
      if (token.isEmpty || token.length > 512) throw const FormatException();
      final bytes = base64Url.decode(token);
      if (base64Url.encode(bytes) != token) throw const FormatException();
      final fields = jsonDecode(utf8.decode(bytes));
      if (fields is! List ||
          fields.length != 4 ||
          fields[0] != 1 ||
          fields[0] is! int ||
          fields[1] != ownerTag ||
          fields[2] is! int ||
          fields[3] is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(fields[3] as String)) {
        throw const FormatException();
      }
      final at = DateTime.fromMicrosecondsSinceEpoch(
        fields[2] as int,
        isUtc: true,
      );
      if (at.microsecondsSinceEpoch != fields[2]) throw const FormatException();
      return _RecordingHistoryCursor(fields[2] as int, fields[3] as String);
    } catch (_) {
      throw const ActivityRecordingException(
        'E_RECORDING_INVALID_CURSOR',
        'The recording history cursor is invalid for the current owner.',
      );
    }
  }
}
