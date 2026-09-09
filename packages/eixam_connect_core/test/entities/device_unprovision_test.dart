import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  test('succeeded covers wipe and already-virgin outcomes', () {
    const status = DeviceStatus(
      deviceId: 'device-1',
      paired: true,
      activated: false,
      connected: true,
      provisioningStatus: DeviceProvisioningStatus.unprovisioned,
    );

    expect(DeviceUnprovisionResult.unprovisioned(status).succeeded, isTrue);
    expect(
      DeviceUnprovisionResult.alreadyUnprovisioned(status).succeeded,
      isTrue,
    );
    expect(
      const DeviceUnprovisionResult.failed(
        DeviceUnprovisionFailure(
          code: DeviceUnprovisionFailureCode.notConnected,
          retryable: true,
        ),
      ).succeeded,
      isFalse,
    );
  });
}
