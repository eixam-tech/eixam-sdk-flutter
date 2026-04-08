import 'package:eixam_connect_core/eixam_connect_core.dart' as core;

import '../sdk/api_sdk_factory.dart';

// Public SDK facade exposed to partner applications.
export 'package:eixam_connect_core/src/interfaces/eixam_connect_sdk.dart';

// Registers the Flutter bootstrap implementation behind the public
// `EixamConnectSdk.bootstrap(...)` entrypoint when the package is imported.
// ignore: unused_element
final bool _bootstrapRegistration = (() {
  core.registerEixamConnectSdkBootstrapper(ApiSdkFactory.bootstrap);
  return true;
})();
