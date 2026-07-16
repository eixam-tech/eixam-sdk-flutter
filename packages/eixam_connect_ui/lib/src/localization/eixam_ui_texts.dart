import 'package:eixam_connect_core/eixam_connect_core.dart';

class EixamUiTexts {
  const EixamUiTexts({
    required this.sosButtonLabel,
    required this.sosIdle,
    required this.sosSending,
    required this.sosSent,
    required this.sosCancelled,
    required this.sosFailed,
    required this.sosUnknownPrefix,
    required this.deathManCheckInTitle,
    required this.deathManCheckInMessage,
    required this.confirmSafety,
    required this.deviceRegionTitle,
    this.deviceRegionPrompt =
        'This update is required to comply with the radio regulations in your '
        'current region. Update the device to continue.',
    this.deviceRegionConfirm = 'Update',
    this.deviceRegionCancel = 'Not now',
    this.deviceRegionRetry = 'Try again',
    required this.deviceRegionApplying,
    required this.deviceRegionSuccess,
    required this.deviceRegionError,
    required this.deviceRegionDismiss,
  });

  factory EixamUiTexts.es() => const EixamUiTexts(
        sosButtonLabel: 'SOS',
        sosIdle: 'SOS inactivo',
        sosSending: 'Enviando SOS...',
        sosSent: 'SOS enviado',
        sosCancelled: 'SOS cancelado',
        sosFailed: 'Error SOS',
        sosUnknownPrefix: 'Estado SOS',
        deathManCheckInTitle: 'Confirmación de seguridad',
        deathManCheckInMessage:
            'Confirma que estás bien para evitar activar el protocolo SOS.',
        confirmSafety: 'Estoy bien',
    deviceRegionTitle: 'Actualización de región requerida',
    deviceRegionPrompt:
        'Esta actualización es obligatoria para cumplir la normativa de '
        'radio de tu región actual. Actualiza el dispositivo para continuar.',
    deviceRegionConfirm: 'Actualizar',
    deviceRegionCancel: 'Ahora no',
    deviceRegionRetry: 'Reintentar',
    deviceRegionApplying: 'Actualizando la región del dispositivo…',
    deviceRegionSuccess: 'La región del dispositivo se ha actualizado.',
        deviceRegionError:
        'No hemos podido actualizar la región del dispositivo. Mantén el '
        'dispositivo conectado e inténtalo de nuevo.',
        deviceRegionDismiss: 'Aceptar',
      );

  factory EixamUiTexts.en() => const EixamUiTexts(
        sosButtonLabel: 'SOS',
        sosIdle: 'SOS inactive',
        sosSending: 'Sending SOS...',
        sosSent: 'SOS sent',
        sosCancelled: 'SOS cancelled',
        sosFailed: 'SOS error',
        sosUnknownPrefix: 'SOS status',
        deathManCheckInTitle: 'Safety check-in',
        deathManCheckInMessage:
            'Confirm you are safe to avoid triggering the SOS protocol.',
        confirmSafety: 'I am safe',
    deviceRegionTitle: 'Device region update required',
    deviceRegionPrompt:
        'This update is required to comply with the radio regulations in '
        'your current region. Update the device to continue.',
    deviceRegionConfirm: 'Update',
    deviceRegionCancel: 'Not now',
    deviceRegionRetry: 'Try again',
    deviceRegionApplying: 'Updating device region…',
    deviceRegionSuccess: 'Device region updated.',
        deviceRegionError:
        'We could not update the device region. Keep the device connected '
        'and try again.',
        deviceRegionDismiss: 'OK',
      );

  factory EixamUiTexts.ca() => const EixamUiTexts(
        sosButtonLabel: 'SOS',
        sosIdle: 'SOS inactiu',
        sosSending: 'Enviant SOS...',
        sosSent: 'SOS enviat',
        sosCancelled: 'SOS cancel·lat',
        sosFailed: 'Error SOS',
        sosUnknownPrefix: 'Estat SOS',
        deathManCheckInTitle: 'Confirmació de seguretat',
        deathManCheckInMessage:
            'Confirma que estàs bé per evitar activar el protocol SOS.',
        confirmSafety: 'Estic bé',
    deviceRegionTitle: 'Actualització de regió necessària',
    deviceRegionPrompt:
        'Aquesta actualització és obligatòria per complir la normativa de '
        'ràdio de la regió actual. Actualitza el dispositiu per continuar.',
    deviceRegionConfirm: 'Actualitzar',
    deviceRegionCancel: 'Ara no',
    deviceRegionRetry: 'Torna-ho a provar',
    deviceRegionApplying: 'Actualitzant la regió del dispositiu…',
    deviceRegionSuccess: 'La regió del dispositiu s’ha actualitzat.',
        deviceRegionError:
        'No hem pogut actualitzar la regió del dispositiu. Mantén el '
        'dispositiu connectat i torna-ho a provar.',
        deviceRegionDismiss: 'D’acord',
      );

  factory EixamUiTexts.fr() => const EixamUiTexts(
        sosButtonLabel: 'SOS',
        sosIdle: 'SOS inactif',
        sosSending: 'Envoi du SOS...',
        sosSent: 'SOS envoyé',
        sosCancelled: 'SOS annulé',
        sosFailed: 'Erreur SOS',
        sosUnknownPrefix: 'État SOS',
        deathManCheckInTitle: 'Confirmation de sécurité',
        deathManCheckInMessage:
            'Confirmez que vous allez bien pour éviter d’activer le protocole SOS.',
        confirmSafety: 'Je vais bien',
    deviceRegionTitle: 'Mise à jour de région requise',
    deviceRegionPrompt:
        'Cette mise à jour est obligatoire pour respecter la réglementation '
        'radio de votre région actuelle. Mettez à jour l’appareil pour continuer.',
    deviceRegionConfirm: 'Mettre à jour',
    deviceRegionCancel: 'Pas maintenant',
    deviceRegionRetry: 'Réessayer',
    deviceRegionApplying: 'Mise à jour de la région de l’appareil…',
    deviceRegionSuccess: 'La région de l’appareil a été mise à jour.',
        deviceRegionError:
        'Nous n’avons pas pu mettre à jour la région de l’appareil. Gardez '
        'l’appareil connecté et réessayez.',
        deviceRegionDismiss: 'OK',
      );

  factory EixamUiTexts.fromLocaleCode(String localeCode) {
    switch (localeCode.toLowerCase()) {
      case 'en':
        return EixamUiTexts.en();
      case 'ca':
        return EixamUiTexts.ca();
      case 'fr':
        return EixamUiTexts.fr();
      case 'es':
      default:
        return EixamUiTexts.es();
    }
  }
  final String sosButtonLabel;
  final String sosIdle;
  final String sosSending;
  final String sosSent;
  final String sosCancelled;
  final String sosFailed;
  final String sosUnknownPrefix;
  final String deathManCheckInTitle;
  final String deathManCheckInMessage;
  final String confirmSafety;
  final String deviceRegionTitle;
  final String deviceRegionPrompt;
  final String deviceRegionConfirm;
  final String deviceRegionCancel;
  final String deviceRegionRetry;
  final String deviceRegionApplying;
  final String deviceRegionSuccess;
  final String deviceRegionError;
  final String deviceRegionDismiss;

  EixamUiTexts copyWith({
    String? sosButtonLabel,
    String? sosIdle,
    String? sosSending,
    String? sosSent,
    String? sosCancelled,
    String? sosFailed,
    String? sosUnknownPrefix,
    String? deathManCheckInTitle,
    String? deathManCheckInMessage,
    String? confirmSafety,
    String? deviceRegionTitle,
    String? deviceRegionPrompt,
    String? deviceRegionConfirm,
    String? deviceRegionCancel,
    String? deviceRegionRetry,
    String? deviceRegionApplying,
    String? deviceRegionSuccess,
    String? deviceRegionError,
    String? deviceRegionDismiss,
  }) {
    return EixamUiTexts(
      sosButtonLabel: sosButtonLabel ?? this.sosButtonLabel,
      sosIdle: sosIdle ?? this.sosIdle,
      sosSending: sosSending ?? this.sosSending,
      sosSent: sosSent ?? this.sosSent,
      sosCancelled: sosCancelled ?? this.sosCancelled,
      sosFailed: sosFailed ?? this.sosFailed,
      sosUnknownPrefix: sosUnknownPrefix ?? this.sosUnknownPrefix,
      deathManCheckInTitle: deathManCheckInTitle ?? this.deathManCheckInTitle,
      deathManCheckInMessage:
          deathManCheckInMessage ?? this.deathManCheckInMessage,
      confirmSafety: confirmSafety ?? this.confirmSafety,
      deviceRegionTitle: deviceRegionTitle ?? this.deviceRegionTitle,
      deviceRegionPrompt: deviceRegionPrompt ?? this.deviceRegionPrompt,
      deviceRegionConfirm: deviceRegionConfirm ?? this.deviceRegionConfirm,
      deviceRegionCancel: deviceRegionCancel ?? this.deviceRegionCancel,
      deviceRegionRetry: deviceRegionRetry ?? this.deviceRegionRetry,
      deviceRegionApplying: deviceRegionApplying ?? this.deviceRegionApplying,
      deviceRegionSuccess: deviceRegionSuccess ?? this.deviceRegionSuccess,
      deviceRegionError: deviceRegionError ?? this.deviceRegionError,
      deviceRegionDismiss: deviceRegionDismiss ?? this.deviceRegionDismiss,
    );
  }

  String labelForSosState(SosState state) {
    switch (state) {
      case SosState.idle:
        return sosIdle;
      case SosState.sending:
        return sosSending;
      case SosState.sent:
        return sosSent;
      case SosState.cancelled:
        return sosCancelled;
      case SosState.failed:
        return sosFailed;
      default:
        return '$sosUnknownPrefix: $state';
    }
  }
}
