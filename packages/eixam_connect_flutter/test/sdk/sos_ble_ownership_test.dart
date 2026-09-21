import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SOS BLE ownership arbitration', () {
    test('keeps Flutter authoritative until native GATT is live', () {
      expect(
        resolveAuthoritativeSosBleRuntimeOwner(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeConnectionLive: false,
        ),
        SosBleRuntimeOwner.flutter,
      );
    });

    test('hands all SOS traffic to the live native owner', () {
      expect(
        resolveAuthoritativeSosBleRuntimeOwner(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeConnectionLive: true,
        ),
        SosBleRuntimeOwner.nativeProtection,
      );
      expect(
        resolveAuthoritativeSosBleRuntimeOwner(
          declaredOwner: ProtectionBleOwner.flutter,
          nativeConnectionLive: true,
        ),
        SosBleRuntimeOwner.flutter,
      );
    });

    test('handoff always leaves a receiver for a physical START', () {
      final ownershipAcrossHandoff = <SosBleRuntimeOwner>[
        resolveAuthoritativeSosBleRuntimeOwner(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeConnectionLive: false,
        ),
        resolveAuthoritativeSosBleRuntimeOwner(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeConnectionLive: true,
        ),
      ];

      expect(ownershipAcrossHandoff, <SosBleRuntimeOwner>[
        SosBleRuntimeOwner.flutter,
        SosBleRuntimeOwner.nativeProtection,
      ]);
    });

    test('START and CANCEL use one authoritative consumer per state', () {
      for (final nativeConnectionLive in <bool>[false, true]) {
        final startOwner = resolveAuthoritativeSosBleRuntimeOwner(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeConnectionLive: nativeConnectionLive,
        );
        final cancelOwner = resolveAuthoritativeSosBleRuntimeOwner(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeConnectionLive: nativeConnectionLive,
        );

        expect(cancelOwner, startOwner);
        expect(<SosBleRuntimeOwner>{startOwner, cancelOwner}, hasLength(1));
      }
    });

    test('native command readiness requires every typed predicate', () {
      NativeProtectionCommandReadiness evaluate({
        ProtectionBleOwner owner = ProtectionBleOwner.androidService,
        bool connected = true,
        bool canonicalCommandPathReady = true,
        bool targetMatches = true,
        bool operationQueueOperational = true,
      }) {
        return evaluateNativeProtectionCommandReadiness(
          declaredOwner: owner,
          serviceBleConnected: connected,
          serviceBleReady: canonicalCommandPathReady,
          exactTargetIdentityMatch: targetMatches,
          operationQueueOperational: operationQueueOperational,
        );
      }

      expect(evaluate().ready, isTrue);
      expect(
        evaluate(targetMatches: false).failure,
        NativeProtectionCommandReadinessFailure.targetIdentityMismatch,
      );
      expect(
        evaluate(canonicalCommandPathReady: false).failure,
        NativeProtectionCommandReadinessFailure.canonicalCommandPathNotReady,
      );
      expect(
        evaluate(operationQueueOperational: false).failure,
        NativeProtectionCommandReadinessFailure.operationQueueFailed,
      );
      expect(
        evaluate(owner: ProtectionBleOwner.flutter).failure,
        NativeProtectionCommandReadinessFailure.ownerNotNative,
      );
    });
  });
}
