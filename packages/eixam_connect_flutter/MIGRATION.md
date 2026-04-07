# Migration

## Public API Boundary Update

Recent releases tighten the public API boundary of `eixam_connect_flutter`.

The supported partner-facing import is now:

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
```

## What Changed

- the root barrel now exposes only the supported public SDK surface
- internal implementation classes are no longer exported from the root package import

## What Partners Should Do

- import only `package:eixam_connect_flutter/eixam_connect_flutter.dart`
- use `ApiSdkFactory`, `EixamConnectSdk`, and the public config/model/enum/event/error types exported there
- move away from any imports under `package:eixam_connect_flutter/src/...`

## No Longer Exported from the Root Barrel

These categories are no longer part of the supported public surface:

- internal repositories
- platform adapters
- BLE and protocol packet classes
- validation and debug helpers
- internal controllers
- runtime and storage internals

## Compatibility Note

Only the symbols exported from `eixam_connect_flutter.dart` should be treated as stable partner API. Anything outside that surface may change without compatibility guarantees.
