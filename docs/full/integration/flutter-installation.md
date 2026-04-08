# Flutter Installation

## Add the package

```yaml
dependencies:
  eixam_connect_flutter:
    git:
      url: https://github.com/eixam-tech/eixam-sdk-flutter
      ref: v0.3.0
      path: packages/eixam_connect_flutter
```

## Import

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
```

## Recommended package boundary

Partner apps should only need the public Flutter package surface. Do not build directly against internal runtime implementation classes unless you are working in a controlled internal validation scenario.

## Next step

Continue with [Flutter Integration](flutter-integration.md).
