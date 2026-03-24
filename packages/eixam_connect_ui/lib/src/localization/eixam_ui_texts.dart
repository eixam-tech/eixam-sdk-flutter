import 'package:eixam_connect_core/eixam_connect_core.dart';

class EixamUiTexts {
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
