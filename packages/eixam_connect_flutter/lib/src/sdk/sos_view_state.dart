import 'package:eixam_connect_core/eixam_connect_core.dart';

class SosViewState {
  const SosViewState({
    required this.label,
    required this.detailLabel,
    required this.canTrigger,
    required this.canCancel,
    this.canConfirm = false,
    this.canAcknowledge = false,
    this.cancelLabel = 'Cancel SOS',
    this.sourceLabel = '-',
  });

  factory SosViewState.fromSdkState({
    required SosState state,
    required bool isBusy,
    SosIncident? incident,
  }) {
    final label = switch (state) {
      SosState.idle => 'Idle',
      SosState.arming => 'Arming',
      SosState.triggerRequested => 'Trigger requested',
      SosState.triggeredLocal => 'Triggered locally',
      SosState.sending => 'Sending',
      SosState.sent => 'Sent',
      SosState.acknowledged => 'Acknowledged',
      SosState.cancelRequested => 'Cancel requested',
      SosState.cancelled => 'Cancelled',
      SosState.resolved => 'Resolved',
      SosState.failed => 'Failed',
    };

    return SosViewState(
      label: label,
      detailLabel: incident?.message ?? incident?.triggerSource ?? '-',
      canTrigger: !isBusy &&
          (state == SosState.idle ||
              state == SosState.failed ||
              state == SosState.cancelled ||
              state == SosState.resolved),
      canCancel: !isBusy &&
          !(state == SosState.idle ||
              state == SosState.failed ||
              state == SosState.cancelled ||
              state == SosState.resolved),
    );
  }

  factory SosViewState.fromDeviceStatus({
    required DeviceSosStatus status,
    required bool isBusy,
  }) {
    final label = switch (status.state) {
      DeviceSosState.inactive => 'Safe',
      DeviceSosState.preConfirm => 'Waiting confirmation',
      DeviceSosState.active => 'Active',
      DeviceSosState.acknowledged => 'Acknowledged',
      DeviceSosState.resolved => 'Resolved',
      DeviceSosState.unknown => 'Unknown',
    };

    final state = status.state;
    return SosViewState(
      label: status.optimistic ? '$label (pending)' : label,
      detailLabel: status.lastEvent,
      canTrigger: !isBusy &&
          (state == DeviceSosState.inactive ||
              state == DeviceSosState.resolved ||
              state == DeviceSosState.unknown),
      canCancel: !isBusy &&
          (state == DeviceSosState.preConfirm ||
              state == DeviceSosState.active ||
              state == DeviceSosState.acknowledged),
      canConfirm: !isBusy && state == DeviceSosState.preConfirm,
      canAcknowledge: !isBusy && state == DeviceSosState.active,
      cancelLabel:
          state == DeviceSosState.preConfirm ? 'Cancel SOS' : 'Resolve SOS',
      sourceLabel: status.derivedFromBlePacket
          ? 'Updated from device packet'
          : 'Updated by app/runtime state',
    );
  }

  final String label;
  final String detailLabel;
  final bool canTrigger;
  final bool canCancel;
  final bool canConfirm;
  final bool canAcknowledge;
  final String cancelLabel;
  final String sourceLabel;
}
