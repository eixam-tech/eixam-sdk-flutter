import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/services.dart';

abstract class BackgroundLocationPlatformAdapter
    implements BackgroundLocationControl {
  Future<void> dispose();
}

class BackgroundLocationAdapterException implements Exception {
  const BackgroundLocationAdapterException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'BackgroundLocationAdapterException($code, $message)';
}

class IosBackgroundLocationPlatformAdapter
    implements BackgroundLocationPlatformAdapter {
  IosBackgroundLocationPlatformAdapter({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    Stream<Object?> Function()? eventStreamFactory,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(_methodChannelName),
        _eventChannel = eventChannel ?? const EventChannel(_eventChannelName),
        _eventStreamFactory = eventStreamFactory {
    _statusController =
        StreamController<BackgroundLocationRuntimeStatus>.broadcast(
            onListen: _startNativeSubscription);
  }

  static const String _methodChannelName =
      'dev.eixam.connect_flutter/background_location/methods';
  static const String _eventChannelName =
      'dev.eixam.connect_flutter/background_location/events';

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final Stream<Object?> Function()? _eventStreamFactory;
  late final StreamController<BackgroundLocationRuntimeStatus>
      _statusController;

  StreamSubscription<Object?>? _nativeSubscription;
  Future<void> _contextOperation = Future<void>.value();
  bool _disposed = false;

  @override
  Future<LocationPermissionSnapshot> getLocationPermissionSnapshot() async {
    _ensureNotDisposed();
    final raw = await _methodChannel.invokeMethod<Object?>(
      'getLocationPermissionSnapshot',
    );
    return _parsePermission(raw);
  }

  @override
  Future<LocationPermissionSnapshot>
      requestLocationWhenInUsePermission() async {
    _ensureNotDisposed();
    final raw = await _methodChannel.invokeMethod<Object?>(
      'requestLocationWhenInUsePermission',
    );
    return _parsePermission(raw);
  }

  @override
  Future<LocationPermissionSnapshot> requestLocationAlwaysPermission() async {
    _ensureNotDisposed();
    final raw = await _methodChannel.invokeMethod<Object?>(
      'requestLocationAlwaysPermission',
    );
    return _parsePermission(raw);
  }

  @override
  Future<BackgroundLocationRuntimeStatus> setBackgroundLocationContext(
    BackgroundLocationContext context, {
    required bool active,
  }) {
    final completer = Completer<BackgroundLocationRuntimeStatus>();
    _contextOperation = _contextOperation.then((_) async {
      try {
        _ensureNotDisposed();
        final current = await getBackgroundLocationStatus();
        final requested = Set<BackgroundLocationContext>.of(
          current.activeContexts,
        );
        if (active) {
          requested.add(context);
        } else {
          requested.remove(context);
        }
        final effectiveMode = resolveBackgroundLocationMode(requested);
        final raw = await _methodChannel.invokeMethod<Object?>(
          'setBackgroundLocationState',
          <String, Object>{
            'requestedContexts': requested.map(_contextName).toList(
                  growable: false,
                ),
            'effectiveMode': effectiveMode.name,
          },
        );
        completer.complete(_parseStatus(raw));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  @override
  Future<BackgroundLocationRuntimeStatus> getBackgroundLocationStatus() async {
    _ensureNotDisposed();
    final raw = await _methodChannel.invokeMethod<Object?>(
      'getBackgroundLocationStatus',
    );
    return _parseStatus(raw);
  }

  @override
  Stream<BackgroundLocationRuntimeStatus> watchBackgroundLocationStatus() {
    _ensureNotDisposed();
    return _statusController.stream;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
    await _statusController.close();
  }

  void _startNativeSubscription() {
    if (_disposed || _nativeSubscription != null) {
      return;
    }
    final nativeStream =
        _eventStreamFactory?.call() ?? _eventChannel.receiveBroadcastStream();
    _nativeSubscription = nativeStream.listen(
      (event) {
        try {
          _statusController.add(_parseStatus(event));
        } catch (error, stackTrace) {
          _statusController.addError(error, stackTrace);
        }
      },
      onError: _statusController.addError,
    );
  }

  LocationPermissionSnapshot _parsePermission(Object? raw) {
    final map = _stringKeyedMap(raw, payloadName: 'permission');
    final servicesEnabled = map['locationServicesEnabled'];
    final authorization = map['authorization'];
    final accuracy = map['accuracyAuthorization'];
    if (servicesEnabled is! bool ||
        authorization is! String ||
        accuracy is! String) {
      throw const BackgroundLocationAdapterException(
        'invalid_native_payload',
        'Native location permission payload has invalid field types.',
      );
    }
    return LocationPermissionSnapshot(
      locationServicesEnabled: servicesEnabled,
      authorizationStatus: switch (authorization) {
        'notDetermined' => LocationAuthorizationStatus.notDetermined,
        'denied' => LocationAuthorizationStatus.denied,
        'restricted' => LocationAuthorizationStatus.restricted,
        'whenInUse' => LocationAuthorizationStatus.whenInUse,
        'always' => LocationAuthorizationStatus.always,
        _ => throw const BackgroundLocationAdapterException(
            'invalid_native_payload',
            'Native location authorization value is unsupported.',
          ),
      },
      accuracyAuthorization: switch (accuracy) {
        'unknown' => LocationAccuracyAuthorization.unknown,
        'reduced' => LocationAccuracyAuthorization.reduced,
        'full' => LocationAccuracyAuthorization.full,
        _ => throw const BackgroundLocationAdapterException(
            'invalid_native_payload',
            'Native location accuracy value is unsupported.',
          ),
      },
    );
  }

  BackgroundLocationRuntimeStatus _parseStatus(Object? raw) {
    final map = _stringKeyedMap(raw, payloadName: 'status');
    final rawContexts = map['activeContexts'];
    final supported = map['isNativePlatformSupported'];
    final running = map['isNativeServiceRunning'];
    final restored = map['wasRestoredAfterRelaunch'];
    final effectiveMode = map['effectiveMode'];
    if (rawContexts is! List<Object?> ||
        supported is! bool ||
        running is! bool ||
        restored is! bool ||
        effectiveMode is! String) {
      throw const BackgroundLocationAdapterException(
        'invalid_native_payload',
        'Native background-location status has invalid field types.',
      );
    }
    final contexts = rawContexts.map(_parseContext).toSet();
    if (resolveBackgroundLocationMode(contexts).name != effectiveMode) {
      throw const BackgroundLocationAdapterException(
        'invalid_native_payload',
        'Native effective mode does not match the canonical Dart reducer.',
      );
    }
    final lastAcceptedAtMs = map['lastAcceptedLocationAt'];
    if (lastAcceptedAtMs != null && lastAcceptedAtMs is! num) {
      throw const BackgroundLocationAdapterException(
        'invalid_native_payload',
        'Native accepted-location timestamp is invalid.',
      );
    }
    return BackgroundLocationRuntimeStatus(
      activeContexts: contexts,
      isNativePlatformSupported: supported,
      isNativeServiceRunning: running,
      permission: _parsePermission(map['permission']),
      lastAcceptedLocationAt: lastAcceptedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (lastAcceptedAtMs as num).toInt(),
              isUtc: true,
            ),
      lastErrorCode: _nullableString(map['lastErrorCode']),
      lastErrorMessage: _nullableString(map['lastErrorMessage']),
      wasRestoredAfterRelaunch: restored,
    );
  }

  Map<String, Object?> _stringKeyedMap(
    Object? raw, {
    required String payloadName,
  }) {
    if (raw is! Map<Object?, Object?> ||
        raw.keys.any((key) => key is! String)) {
      throw BackgroundLocationAdapterException(
        'invalid_native_payload',
        'Native background-location $payloadName is not a string-keyed map.',
      );
    }
    return raw.cast<String, Object?>();
  }

  BackgroundLocationContext _parseContext(Object? raw) {
    return switch (raw) {
      'sharing' => BackgroundLocationContext.sharing,
      'dmp' => BackgroundLocationContext.dmp,
      'sos' => BackgroundLocationContext.sos,
      _ => throw const BackgroundLocationAdapterException(
          'invalid_native_payload',
          'Native background-location context is unsupported.',
        ),
    };
  }

  String _contextName(BackgroundLocationContext context) => context.name;

  String? _nullableString(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw const BackgroundLocationAdapterException(
        'invalid_native_payload',
        'Native background-location error metadata is invalid.',
      );
    }
    return value;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('The iOS background-location adapter is disposed.');
    }
  }
}

class UnsupportedBackgroundLocationPlatformAdapter
    implements BackgroundLocationPlatformAdapter {
  UnsupportedBackgroundLocationPlatformAdapter();

  final Set<BackgroundLocationContext> _activeContexts =
      <BackgroundLocationContext>{};

  LocationPermissionSnapshot get _permission =>
      const LocationPermissionSnapshot(
        locationServicesEnabled: false,
        authorizationStatus: LocationAuthorizationStatus.notDetermined,
        accuracyAuthorization: LocationAccuracyAuthorization.unknown,
      );

  BackgroundLocationRuntimeStatus get _status =>
      BackgroundLocationRuntimeStatus(
        activeContexts: _activeContexts,
        isNativePlatformSupported: false,
        isNativeServiceRunning: false,
        permission: _permission,
        lastErrorCode: 'unsupported_platform',
        lastErrorMessage:
            'Native background location is unsupported on this platform.',
      );

  @override
  Future<LocationPermissionSnapshot> getLocationPermissionSnapshot() async =>
      _permission;

  @override
  Future<LocationPermissionSnapshot>
      requestLocationWhenInUsePermission() async => _permission;

  @override
  Future<LocationPermissionSnapshot> requestLocationAlwaysPermission() async =>
      _permission;

  @override
  Future<BackgroundLocationRuntimeStatus> setBackgroundLocationContext(
    BackgroundLocationContext context, {
    required bool active,
  }) async {
    if (active) {
      _activeContexts.add(context);
    } else {
      _activeContexts.remove(context);
    }
    return _status;
  }

  @override
  Future<BackgroundLocationRuntimeStatus> getBackgroundLocationStatus() async =>
      _status;

  @override
  Stream<BackgroundLocationRuntimeStatus> watchBackgroundLocationStatus() =>
      Stream<BackgroundLocationRuntimeStatus>.value(_status);

  @override
  Future<void> dispose() async {}
}
