import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Internal capability for observing a known preferred device through the
/// SDK's existing BLE discovery path.
abstract class PreferredDeviceAvailabilityRepository {
  Future<bool> isPreferredDeviceAdvertising({
    required PreferredDevice device,
    required Duration scanTimeout,
  });
}
