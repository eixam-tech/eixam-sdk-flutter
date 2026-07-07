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
        deviceRegionTitle: 'Región de radio del dispositivo',
        deviceRegionApplying:
            'Configurando la región de radio correcta para tu país…',
        deviceRegionSuccess:
            'Tu dispositivo ya usa la región de radio legal para tu ubicación.',
        deviceRegionError:
            'El dispositivo no pudo aplicar la región. Se reintentará '
            'automáticamente.',
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
        deviceRegionTitle: 'Device radio region',
        deviceRegionApplying:
            'Setting the correct radio region for your country…',
        deviceRegionSuccess:
            'Your device now uses the radio region legal for your location.',
        deviceRegionError:
            'The device could not apply the region. It will retry '
            'automatically.',
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
        deviceRegionTitle: 'Regió de ràdio del dispositiu',
        deviceRegionApplying:
            'Configurant la regió de ràdio correcta per al teu país…',
        deviceRegionSuccess:
            'El teu dispositiu ja fa servir la regió de ràdio legal per a la '
            'teva ubicació.',
        deviceRegionError:
            'El dispositiu no ha pogut aplicar la regió. Es tornarà a provar '
            'automàticament.',
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
        deviceRegionTitle: 'Région radio de l’appareil',
        deviceRegionApplying:
            'Configuration de la région radio adaptée à votre pays…',
        deviceRegionSuccess:
            'Votre appareil utilise désormais la région radio légale pour '
            'votre position.',
        deviceRegionError:
            'L’appareil n’a pas pu appliquer la région. Une nouvelle tentative '
            'aura lieu automatiquement.',
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
