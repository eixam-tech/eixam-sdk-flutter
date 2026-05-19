import '../entities/sos_incident.dart';
import '../entities/os_sos_widget_activation.dart';
import '../entities/tracking_position.dart';
import '../interfaces/sos_repository.dart';

/// Triggers an SOS flow through the configured repository.
class TriggerSosUseCase {
  final SosRepository repository;

  const TriggerSosUseCase(this.repository);

  Future<SosIncident> call({
    String? message,
    String triggerSource = 'button_ui',
    TrackingPosition? positionSnapshot,
    OsSosWidgetActivation? osWidgetActivation,
  }) {
    return repository.triggerSos(
      message: message,
      triggerSource: triggerSource,
      positionSnapshot: positionSnapshot,
      osWidgetActivation: osWidgetActivation,
    );
  }
}
