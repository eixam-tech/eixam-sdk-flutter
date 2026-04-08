# EIXAM Flutter Example

This example is the canonical in-repo smoke-test app for external partners
integrating `eixam_connect_flutter`.

## Primary smoke-test path

Use the app in this order:

1. bootstrap the SDK
2. include or apply the signed session
3. request permissions
4. validate one core flow:
   - diagnostics, or
   - device connect, or
   - SOS

The first sections in the UI are intentionally ordered around that path.

## Advanced sections

The example also keeps a few broader public-SDK surfaces available for manual
validation:

- device activation
- emergency contacts
- extra diagnostics refresh actions

These are secondary and are not required for a minimal partner smoke test.

## Public API boundary

The example uses only the supported public SDK import:

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
```
