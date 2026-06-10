import '../entities/sos_incident.dart';
import '../entities/os_sos_widget_activation.dart';
import '../entities/tracking_position.dart';
import '../interfaces/sos_repository.dart';

/// Triggers an SOS flow through the configured repository.
class TriggerSosUseCase {

  const TriggerSosUseCase(this.repository);
  final SosRepository repository;

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
