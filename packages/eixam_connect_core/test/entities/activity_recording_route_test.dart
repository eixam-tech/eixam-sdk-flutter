import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  test('point retains TAG coordinates, opaque key and existing provenance', () {
    final sampledAt = DateTime(2026, 10, 19, 10);
    final point = SdkActivityRoutePoint(
      stableSampleKey: 'opaque-sample',
      sampledAt: sampledAt,
      latitude: 42.1,
      longitude: 1.5,
      delivery: EixamDevicePositionDelivery.recovered,
      altitudeMeters: 1200,
    );
    expect(point.stableSampleKey, 'opaque-sample');
    expect(point.sampledAt, sampledAt.toUtc());
    expect(point.sampledAt.isUtc, isTrue);
    expect(point.latitude, 42.1);
    expect(point.longitude, 1.5);
    expect(point.delivery, EixamDevicePositionDelivery.recovered);
    expect(point.altitudeMeters, 1200);
    expect(_point('live').altitudeMeters, isNull);
    expect(_point('live').delivery, EixamDevicePositionDelivery.live);
  });

  test('segment snapshots its points and exposes an unmodifiable list', () {
    final point = _point('a');
    final source = [point];
    final segment = SdkActivityRouteSegment(
      segmentId: 'segment',
      points: source,
    );
    source.clear();
    expect(segment.points, [point]);
    expect(() => segment.points.add(point), throwsUnsupportedError);
    expect(() => segment.points[0] = point, throwsUnsupportedError);
    expect(() => segment.points.clear(), throwsUnsupportedError);
  });

  test('open and closed gap boundaries preserve UTC instants', () {
    final from = DateTime(2026, 10, 19, 10);
    final until = from.add(const Duration(minutes: 2));
    final open = SdkActivityRouteGap(
      gapId: 'open',
      from: from,
      reason: ActivityRecordingGapReason.deviceUnavailable,
      state: ActivityRecordingGapState.pending,
    );
    final closed = SdkActivityRouteGap(
      gapId: 'closed',
      from: from,
      until: until,
      reason: ActivityRecordingGapReason.runtimeUnavailable,
      state: ActivityRecordingGapState.unresolved,
    );
    expect(open.from, from.toUtc());
    expect(open.from.isUtc, isTrue);
    expect(open.until, isNull);
    expect(closed.from, from.toUtc());
    expect(closed.until, until.toUtc());
    expect(closed.until!.isUtc, isTrue);
    expect(closed.state, ActivityRecordingGapState.unresolved);
  });

  test('empty route has a representable terminal page', () {
    final page = SdkActivityRoutePage(
      recordingId: 'recording',
      routeRevision: 0,
      segments: [],
      gaps: [],
      isLast: true,
    );
    expect(page.recordingId, 'recording');
    expect(page.routeRevision, 0);
    expect(page.segments, isEmpty);
    expect(page.gaps, isEmpty);
    expect(page.isLast, isTrue);
    expect(() => page.segments.clear(), throwsUnsupportedError);
    expect(() => page.gaps.clear(), throwsUnsupportedError);
  });

  test('page copies collections and nested segment points stay immutable', () {
    final point = _point('a');
    final points = [point];
    final segment = SdkActivityRouteSegment(segmentId: 's', points: points);
    final gap = SdkActivityRouteGap(
      gapId: 'gap',
      from: point.sampledAt,
      reason: ActivityRecordingGapReason.rejectedSamples,
      state: ActivityRecordingGapState.unresolved,
    );
    final segments = [segment];
    final gaps = [gap];
    final page = SdkActivityRoutePage(
      recordingId: 'r',
      routeRevision: 2,
      segments: segments,
      gaps: gaps,
      isLast: true,
    );
    points.clear();
    segments.clear();
    gaps.clear();
    expect(page.segments.single.points, [point]);
    expect(page.gaps, [gap]);
    expect(() => page.segments.add(segment), throwsUnsupportedError);
    expect(() => page.segments[0] = segment, throwsUnsupportedError);
    expect(() => page.gaps.add(gap), throwsUnsupportedError);
    expect(() => page.gaps[0] = gap, throwsUnsupportedError);
    expect(() => page.segments.single.points.clear(), throwsUnsupportedError);
  });

  test('same segment ID can continue across a consistent revision', () {
    final pages = [
      for (var i = 0; i < 2; i++)
        SdkActivityRoutePage(
          recordingId: 'r',
          routeRevision: 7,
          segments: [
            SdkActivityRouteSegment(
              segmentId: 'continuation',
              points: [_point('$i')],
            ),
          ],
          gaps: [],
          isLast: i == 1,
        ),
    ];
    expect(pages.map((page) => page.routeRevision), [7, 7]);
    expect(pages.map((page) => page.segments.single.segmentId), [
      'continuation',
      'continuation',
    ]);
    expect(pages.map((page) => page.isLast), [false, true]);
  });
}

SdkActivityRoutePoint _point(String key) => SdkActivityRoutePoint(
  stableSampleKey: key,
  sampledAt: DateTime.utc(2026, 10, 19, 10),
  latitude: 42,
  longitude: 1,
  delivery: EixamDevicePositionDelivery.live,
);
