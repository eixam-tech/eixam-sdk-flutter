/// Picks the time a TAG link drop should be counted from.
///
/// A drop seen by the native Protection owner carries its own timestamp, which
/// is the honest start of the absence when Dart learns about it late. A stale
/// native event must never move the deadline into the past and cause an
/// immediate false alert, so it is used only when it is:
/// - the native `deviceDisconnected` event itself,
/// - not in the future,
/// - newer than the last time this run saw the link up, and
/// - at most [maxAge] old.
/// Otherwise the drop counts from [now].
abstract final class TagDropTime {
  static const Duration maxAge = Duration(hours: 24);

  static DateTime resolve({
    required DateTime now,
    required bool nativeEventIsDisconnect,
    required DateTime? nativeEventAt,
    required DateTime? lastSeenConnectedAt,
  }) {
    final at = nativeEventAt;
    if (!nativeEventIsDisconnect || at == null) return now;
    if (at.isAfter(now) || now.difference(at) > maxAge) return now;
    final seen = lastSeenConnectedAt;
    if (seen != null && !at.isAfter(seen)) return now;
    return at;
  }
}
