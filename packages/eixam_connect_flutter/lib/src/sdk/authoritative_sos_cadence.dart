import 'package:eixam_connect_core/eixam_connect_core.dart';

/// SDK-internal telemetry cadence input produced by an accepted authoritative
/// SOS lifecycle decision.
final class AuthoritativeSosCadence {
  const AuthoritativeSosCadence({
    required this.lifecycleRevision,
    required this.lifecycleStage,
    required this.desiredLocalSosOwnership,
  });

  final int lifecycleRevision;
  final SosLifecycleStage lifecycleStage;
  final bool desiredLocalSosOwnership;
}
