# Changelog

## 0.2.0

- introduced a clean partner-facing public API boundary centered on `package:eixam_connect_flutter/eixam_connect_flutter.dart`
- stopped exporting internal repositories, controllers, BLE/protocol packet helpers, platform adapters, and runtime/storage internals from the root barrel
- added `PUBLIC_API.md` to define the official supported integration surface
- added a minimal partner-style example app showing SDK initialization, session setup, permissions, device flow, contacts, SOS, and diagnostics
- refreshed package documentation to be external-partner oriented
