# EIXAM project notes

- Flutter/Dart monorepo.
- Main goal now: EIXAM Control App + real BLE pairing.
- Keep current SDK architecture. Do not redesign unless necessary.
- BLE pairing flow already works on real device.
- Real device currently exposes:
  - service ea00
  - characteristics ea01, ea02, ea03
- ea04 may be missing on current firmware, so compatibility must be soft.
- Do not validate devices by advertised name. Validate after connect/discoverServices.
- Current priority:
  1. Device detail screen
  2. BLE debug section
  3. TEL/SOS subscription visibility
  4. Better connection diagnostics