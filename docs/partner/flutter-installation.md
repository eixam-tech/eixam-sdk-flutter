# Flutter Installation

## Add the package

For the planned `0.1.0` release, use the agreed EIXAM release tag when it is provided during release handoff.

```yaml
dependencies:
  eixam_connect_flutter:
    git:
      url: https://github.com/eixam-tech/eixam-sdk-flutter
      ref: <agreed-0.1.0-release-tag>
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
