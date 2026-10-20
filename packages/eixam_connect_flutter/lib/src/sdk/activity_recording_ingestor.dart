import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/activity_recording_record.dart';
import '../data/datasources_local/activity_recording_route_data.dart';
import '../data/datasources_local/activity_recording_store.dart';
import '../activity/activity_recording_source_identity.dart';
import '../device/eixam_tel_live_batch_packet.dart';

/// Consumes decoded TAG evidence, never phone/resolved/backend positions.
/// The controller owns generation/session/lifecycle serialization; SQL owns the
/// durable ledger, topology and metrics in the same transaction as the summary.
final class ActivityRecordingIngestor {
  const ActivityRecordingIngestor();

  Future<ActivityRecordingRecord> ingest(
    ActivityRecordingTransaction tx,
    ActivityRecordingRecord record,
    EixamDevicePositionBatch batch,
    DateTime now, {
    bool recovered = false,
  }) {
    final r = record.value;
    final device = ActivityRecordingSourceIdentity.normalize(
      batch.deviceIdentity,
    );
    if (r.phase == ActivityRecordingPhase.finished ||
        r.deviceIdentity == null ||
        device != r.deviceIdentity ||
        batch.source != SdkLocationSource.connectedDevice ||
        batch.delivery !=
            (recovered
                ? EixamDevicePositionDelivery.recovered
                : EixamDevicePositionDelivery.live)) {
      return Future.value(record);
    }
    final evidence = <ActivityRecordingRouteEvidence>[];
    for (final sample in batch.samples) {
      final at = sample.sampledAt?.toUtc();
      if (sample.source != SdkLocationSource.connectedDevice ||
          sample.stableSampleKey.isEmpty ||
          at == null ||
          at.isBefore(r.recordingStartedAt) ||
          (r.endedAt != null && at.isAfter(r.endedAt!)) ||
          (!recovered &&
              at.isBefore(
                batch.receivedAt.toUtc().subtract(
                  EixamTelLiveBatchPacket.maximumPastAge,
                ),
              )) ||
          at.isAfter(
            batch.receivedAt.toUtc().add(
              EixamTelLiveBatchPacket.maximumFutureSkew,
            ),
          ) ||
          at.isAfter(
            recovered
                ? now.toUtc()
                : now.toUtc().add(EixamTelLiveBatchPacket.maximumFutureSkew),
          )) {
        continue;
      }
      final valid =
          EixamGeoCoordinates.isValidFix(sample.latitude, sample.longitude) &&
          (sample.altitudeMeters == null || sample.altitudeMeters!.isFinite);
      evidence.add(
        ActivityRecordingRouteEvidence(
          at,
          sample.stableSampleKey,
          valid
              ? SdkActivityRoutePoint(
                  stableSampleKey: sample.stableSampleKey,
                  sampledAt: at,
                  latitude: sample.latitude,
                  longitude: sample.longitude,
                  altitudeMeters: sample.altitudeMeters,
                  delivery: batch.delivery,
                )
              : null,
        ),
      );
    }
    return tx.ingestRoute(record, evidence);
  }
}
