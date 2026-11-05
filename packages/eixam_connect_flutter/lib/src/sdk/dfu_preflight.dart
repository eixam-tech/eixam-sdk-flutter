import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../device/ble_adapter_state.dart';

/// Minimum phone battery before any user-started DFU. A legacy transfer runs
/// about 4 minutes after a ~30 s erase at MTU 23, and a flat phone mid-transfer
/// strands the TAG without an application. Conservative on purpose.
const int dfuMinPhoneBatteryPercent = 30;

/// Same check while the phone is charging.
const int dfuMinPhoneBatteryPercentWhenCharging = 10;

class PhoneBatteryReading {
  const PhoneBatteryReading({required this.percent, required this.charging});

  /// Null when the platform could not read the level.
  final int? percent;

  /// Null when the platform could not read the charging state.
  final bool? charging;
}

/// Null means the platform could not report the battery; that never blocks.
typedef PhoneBatteryProvider = Future<PhoneBatteryReading?> Function();

/// Null means unknown; unknown never blocks.
typedef ScreenAwakeProvider = Future<bool?> Function();
typedef AppForegroundProvider = bool? Function();
typedef BleAdapterStateProvider = Future<BleAdapterState> Function();

/// Reads the phone battery through the existing firmware DFU method channel.
Future<PhoneBatteryReading?> readPlatformPhoneBattery({
  MethodChannel channel = const MethodChannel(
    'dev.eixam.connect_flutter/firmware_dfu/methods',
  ),
}) async {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return null;
  try {
    final raw = await channel.invokeMapMethod<String, dynamic>('phoneBattery');
    if (raw == null) return null;
    final percent = raw['percent'];
    return PhoneBatteryReading(
      percent: percent is int ? percent : null,
      charging: raw['charging'] as bool?,
    );
  } catch (_) {
    return null;
  }
}

/// Whether the screen is on (Android `PowerManager.isInteractive`; iOS: the app
/// is active). Keeping it on during the transfer is the host's job (wakelock);
/// the SDK only refuses to start while the screen is off.
Future<bool?> readPlatformScreenAwake({
  MethodChannel channel = const MethodChannel(
    'dev.eixam.connect_flutter/firmware_dfu/methods',
  ),
}) async {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return null;
  try {
    return await channel.invokeMethod<bool>('screenAwake');
  } catch (_) {
    return null;
  }
}

/// Pre-flight shared by every user-started DFU (update, migration, recovery):
/// adapter on, app foreground, screen awake, phone battery level and charging
/// state.
///
/// Each check is pass, warning or fail. A fail is a [FirmwareUpdateException]
/// whose code is a [DfuPreflightFailure] name and is thrown only for a value
/// that was actually read and is below its threshold, or a precondition known to
/// be false (Bluetooth off, app in background, screen off). A value that cannot
/// be read is returned as a [DfuPreflightWarning] and never blocks.
Future<List<DfuPreflightWarning>> runDfuPreflight({
  BleAdapterStateProvider? adapterState,
  AppForegroundProvider? appForeground,
  ScreenAwakeProvider? screenAwake,
  PhoneBatteryProvider? phoneBattery,
}) async {
  final warnings = <DfuPreflightWarning>[];
  if (adapterState != null) {
    final state = await adapterState();
    if (state == BleAdapterState.poweredOff) {
      throw FirmwareUpdateException(
        DfuPreflightFailure.bluetoothOff.name,
        'Bluetooth is turned off.',
      );
    }
    if (state == BleAdapterState.unknown) {
      warnings.add(DfuPreflightWarning.bluetoothStateUnknown);
    }
  }
  if (appForeground != null) {
    final foreground = appForeground();
    if (foreground == false) {
      throw FirmwareUpdateException(
        DfuPreflightFailure.appNotForeground.name,
        'The app must be in the foreground.',
      );
    }
    if (foreground == null)
      warnings.add(DfuPreflightWarning.appForegroundUnknown);
  }
  if (screenAwake != null) {
    final awake = await screenAwake();
    if (awake == false) {
      throw FirmwareUpdateException(
        DfuPreflightFailure.screenNotAwake.name,
        'The screen must be on.',
      );
    }
    if (awake == null) warnings.add(DfuPreflightWarning.screenStateUnknown);
  }
  if (phoneBattery != null) {
    final reading = await phoneBattery();
    final percent = reading?.percent;
    if (percent == null) {
      warnings.add(DfuPreflightWarning.phoneBatteryUnknown);
    } else {
      final charging = reading!.charging;
      if (charging == null)
        warnings.add(DfuPreflightWarning.phoneChargingUnknown);
      // Unknown charging state never tightens the threshold.
      final minimum = charging == false
          ? dfuMinPhoneBatteryPercent
          : dfuMinPhoneBatteryPercentWhenCharging;
      if (percent < minimum) {
        throw FirmwareUpdateException(
          DfuPreflightFailure.phoneBatteryLow.name,
          'Phone battery is below $minimum %.',
        );
      }
    }
  }
  return warnings;
}
