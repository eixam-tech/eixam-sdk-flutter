# Flutter Installation

This page explains how an external Flutter customer installs the EIXAM Flutter SDK in a host app.

Do not assume access to the EIXAM monorepo. Installation should use the delivery channel provided during onboarding.

## Supported Installation Modes

EIXAM supports two installation modes for Flutter partners.

### 1. Private Git Tag

This is the typical initial rollout model for early partner integrations.

Add the SDK from the private Git repository and the approved release tag:

```yaml
dependencies:
  eixam_connect_flutter:
    git:
      url: git@<git-host>:<org>/<repo>.git
      ref: <sdk-release-tag>
      path: packages/eixam_connect_flutter
```

EIXAM will provide:

- repository access
- the tag or release ref to use
- any access instructions required by your Git host

### 2. Private Package Repository

This is the future or enterprise-ready rollout model when package distribution is handled through a private registry.

Add the SDK using the package source and version provided by EIXAM:

```yaml
dependencies:
  eixam_connect_flutter: <sdk-version>
```

Your team will also need the private package repository configuration required by your organization or by EIXAM.

EIXAM will provide:

- the package repository endpoint or onboarding instructions
- the package name and approved version
- any access token or authentication requirements

## Import Rule

The host app should import only the public SDK entrypoint:

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
```

Do not import internal `src/...` files.

## What the SDK Provides

The SDK provides the EIXAM integration layer for:

- session bootstrap
- SOS flows
- device lifecycle
- permissions and notifications
- telemetry and diagnostics

## What the Partner App Provides

The partner app is responsible for implementing its own UI and product experience on top of the SDK.

That means your team should:

- build screens, navigation, and branding in the host app
- call the public SDK methods from your app logic
- render SDK state in your own UI
- use the official examples as references for implementation patterns

The SDK is the service and runtime layer. The UI remains partner-owned.

## Next Steps

After installation:

1. open [Quickstart](./quickstart.md)
2. review [Flutter Integration](./flutter-integration.md)
3. review [Public API](./public-api.md)
4. implement your app UI using [API Examples](./public-api-examples.md)
