import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SOS BLE ownership arbitration', () {
    test('native connected without command readiness remains preparing', () {
      expect(
        resolveSosBleOwnershipState(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeCommandReady: false,
        ),
        SosBleOwnershipState.nativePreparing,
      );
    });

    test('hands SOS traffic to native only after command readiness', () {
      expect(
        resolveSosBleOwnershipState(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeCommandReady: true,
        ),
        SosBleOwnershipState.nativeReadyOwner,
      );
      expect(
        resolveSosBleOwnershipState(
          declaredOwner: ProtectionBleOwner.flutter,
          nativeCommandReady: true,
        ),
        SosBleOwnershipState.flutterOwner,
      );
    });

    test('handoff exposes preparing before ready exactly once', () {
      final ownershipAcrossHandoff = <SosBleOwnershipState>[
        resolveSosBleOwnershipState(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeCommandReady: false,
        ),
        resolveSosBleOwnershipState(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeCommandReady: true,
        ),
      ];

      expect(ownershipAcrossHandoff, <SosBleOwnershipState>[
        SosBleOwnershipState.nativePreparing,
        SosBleOwnershipState.nativeReadyOwner,
      ]);
    });

    test('START and CANCEL use one authoritative consumer per state', () {
      for (final nativeCommandReady in <bool>[false, true]) {
        final startOwner = resolveSosBleOwnershipState(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeCommandReady: nativeCommandReady,
        );
        final cancelOwner = resolveSosBleOwnershipState(
          declaredOwner: ProtectionBleOwner.androidService,
          nativeCommandReady: nativeCommandReady,
        );

        expect(cancelOwner, startOwner);
        expect(<SosBleOwnershipState>{startOwner, cancelOwner}, hasLength(1));
      }
    });

    test('native command readiness requires every typed predicate', () {
      NativeProtectionCommandReadiness evaluate({
        ProtectionBleOwner owner = ProtectionBleOwner.androidService,
        bool connected = true,
        bool serviceReady = true,
        bool cmdEa04Ready = true,
        bool targetMatches = true,
        bool operationQueueOperational = true,
      }) {
        return evaluateNativeProtectionCommandReadiness(
          declaredOwner: owner,
          serviceBleConnected: connected,
          serviceReady: serviceReady,
          cmdEa04Ready: cmdEa04Ready,
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
        evaluate(serviceReady: false).failure,
        NativeProtectionCommandReadinessFailure.canonicalCommandPathNotReady,
      );
      expect(
        evaluate(cmdEa04Ready: false).failure,
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

    test('single-owner invariant rejects settled dual GATT state', () {
      expect(
        evaluateSosBleSingleOwnerInvariant(
          nativeDeclared: true,
          flutterOwner: false,
          flutterReleaseSettled: true,
          nativeGattConnected: true,
          flutterGattConnected: true,
        ),
        SosBleSingleOwnerViolation.nativeOwnerWithFlutterGatt,
      );
      expect(
        evaluateSosBleSingleOwnerInvariant(
          nativeDeclared: true,
          flutterOwner: false,
          flutterReleaseSettled: false,
          nativeGattConnected: true,
          flutterGattConnected: true,
        ),
        SosBleSingleOwnerViolation.none,
      );
      expect(
        evaluateSosBleSingleOwnerInvariant(
          nativeDeclared: false,
          flutterOwner: true,
          flutterReleaseSettled: false,
          nativeGattConnected: true,
          flutterGattConnected: false,
        ),
        SosBleSingleOwnerViolation.flutterOwnerWithNativeGatt,
      );
      expect(
        evaluateSosBleSingleOwnerInvariant(
          nativeDeclared: false,
          flutterOwner: false,
          flutterReleaseSettled: false,
          nativeGattConnected: true,
          flutterGattConnected: false,
        ),
        SosBleSingleOwnerViolation.none,
      );
    });
  });
}
