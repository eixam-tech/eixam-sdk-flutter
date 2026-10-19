import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Validated private evidence. A null point declares a rejected in-window fix,
/// never a substitute coordinate. Phone/backend sources cannot construct this
/// through the production recorder path.
final class ActivityRecordingRouteEvidence {
  const ActivityRecordingRouteEvidence(this.at, this.key, this.point);
  final DateTime at;
  final String key;
  final SdkActivityRoutePoint? point;
}

final class ActivityRecordingRouteCursor {
  const ActivityRecordingRouteCursor(this.time, this.kind, this.key);
  final int time;
  final int kind;
  final String key;
}

final class ActivityRecordingRouteSlice {
  const ActivityRecordingRouteSlice(
    this.segments,
    this.gaps,
    this.last,
    this.next,
  );
  final List<SdkActivityRouteSegment> segments;
  final List<SdkActivityRouteGap> gaps;
  final bool last;
  final ActivityRecordingRouteCursor? next;
}
