import 'package:eixam_control_app/src/bootstrap/validation_backend_config.dart';
import 'package:eixam_control_app/src/features/operational_demo/validation_session_preset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'EIXAM staging preset creates a staging draft with a unique user id seed',
      () {
    final draft = ValidationSessionPreset.eixamStaging.createDraft(
      now: DateTime.utc(2026, 4, 9, 13, 45, 12, 34, 567),
    );

    expect(draft.backendPreset, ValidationBackendPreset.staging);
    expect(draft.appId, 'app_u8eetxk3kqgf');
    expect(
      draft.externalUserId,
      'eixam-staging-20260409-134512-034',
    );
    expect(draft.userHash, isEmpty);
  });
}
