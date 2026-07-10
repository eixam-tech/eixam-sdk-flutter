# SEC-NET Hardening Inventory

Date: 2026-06-25

Scope: SDK/app-only network security inventory for `/Users/roger/flutterdev/eixam-sdk-flutter` and read-only app reference at `/Users/roger/flutterdev/eixam_commecial_app/eixam-app`.

This document records current SDK/app posture and next actions only. It does not change runtime behavior and must not be used to claim backend, firmware, native Android/iOS, broker, certificate, token-rotation, or infrastructure remediation.

## Classification Legend

- Fixed SDK/App: implemented within the SDK/app boundary and covered by current source/tests.
- Strongly mitigated SDK/App: meaningful SDK/app guardrails are in place, but backend/platform controls remain necessary.
- Partially mitigated SDK/App: exposure is reduced, but important SDK/app work remains.
- Design-only: documented plan or inventory without runtime enforcement.
- Blocked by backend/platform: requires server, broker, platform trust, firmware, or native policy work outside this pass.
- Future hardening: valid next security improvement that is not part of the completed SDK/app remediation.

## Current Posture

| Area | Classification | Evidence inspected | Current posture | Remaining risk / next action |
| --- | --- | --- | --- | --- |
| API endpoint validation | Strongly mitigated SDK/App | SDK `transport_security_validator.dart`, app `app_config.dart`, `transport_security_validator_test.dart`, `app_config_test.dart` | SDK HTTP transport requires HTTPS for `apiBaseUrl`; app auth config requires secure auth endpoints in profile/release; debug may allow only explicit local insecure endpoints. Endpoint diagnostics redact URI userinfo/query. | This validates schemes/client config only. Server-side endpoint authorization, infrastructure policy, certificate pinning, and custom TLS trust are not proven here. |
| MQTT/WebSocket endpoint validation | Strongly mitigated SDK/App | SDK `transport_security_validator.dart`, `sdk_mqtt_contract.dart`, `mqtt5_sdk_transport.dart`, app custom realtime validation | SDK realtime endpoints must use `wss`, `ssl`, or `tls`, with insecure `ws`/`mqtt`/`tcp` allowed only for explicit debug local development. MQTT connect requests are validated before transport construction and again in `Mqtt5SdkTransport`. App custom realtime config follows the same secure-scheme rule for release/profile. | `wss` is accepted by scheme, but the MQTT client's `secure` flag is only set for `ssl`/`tls`; confirm library semantics for WebSocket TLS before claiming transport-level TLS beyond scheme validation. Certificate pinning is not implemented. Broker-side authorization remains backend/platform work. |
| SOS trigger transport policy | Fixed SDK/App | `mqtt_operational_sos_repository.dart`, `mqtt_realtime_client.dart`, `http_sos_remote_data_source.dart` | Operational SOS triggers publish via MQTT. The HTTP SOS trigger path is explicitly blocked with `E_HTTP_SOS_TRIGGER_BLOCKED` and diagnostics state `trigger_must_use_mqtt`. | Preserve the MQTT-only trigger contract. Do not re-enable REST trigger without a new audit decision and backend contract. |
| SOS cancel/read-only HTTP policy | Strongly mitigated SDK/App | `mqtt_operational_sos_repository.dart`, `http_sos_remote_data_source.dart` | Cancel, resolve, active-SOS rehydration, and history/read-only flows can still use the HTTP SOS data source. This preserves current lifecycle/read behavior while keeping trigger on MQTT. | HTTP cancel/read-only remains dependent on HTTPS endpoint validation and backend authorization. Do not describe HTTP SOS as fully removed; only HTTP trigger is blocked. |
| MQTT lifecycle authority gate | Strongly mitigated SDK/App | `mqtt_operational_sos_repository.dart`, lifecycle authority tests | Realtime SOS lifecycle events are accepted only for active incident identity, client incident identity, trusted correlation id, or cycle key. External-only/history-only lifecycle events and mismatched incidents are rejected and logged. | This is client-side authority gating. Backend topic authorization, server incident authority, and relay-origin proof remain backend/protocol work. |
| Auth header/token handling | Partially mitigated SDK/App | SDK `sdk_http_transport.dart`, `sdk_mqtt_contract.dart`, app `live_auth_api_client.dart`, app auth/session stores | SDK HTTP uses `Authorization: Bearer <userHash>` plus `X-App-ID`/`X-User-ID`; app auth uses `Authorization: Bearer <accessToken>` for authenticated routes. MQTT username is `sdk:<appId>:<externalUserId>` and password is `session.userHash`. SDK session writes no longer persist unused SDK refresh token. | Bearer/userHash and MQTT password material still exist in process and may be persisted as required session state. Broker credential rotation and backend token refresh/rotation policy are not addressed. Do not log raw headers/tokens. |
| Diagnostics redaction | Fixed SDK/App | SDK `security_diagnostics_redactor.dart`, HTTP SOS request logging, tracker/local storage docs, app diagnostics redaction references | SDK diagnostics redact auth headers, payload/body summaries, location, identifiers, topics/endpoints, token-like JSON keys, userHash, secrets, passwords, device ids, node ids, incident ids, and coordinates outside sensitive/debug allowance. HTTP SOS header logs explicitly print redacted `Authorization`. App diagnostics redaction exists and is covered in the current QA gate list. | Future diagnostics can regress this. Require redaction review for any new endpoint, payload, header, MQTT topic, identity, or location diagnostic. |
| Local/secure storage interaction | Partially mitigated SDK/App | `local-storage-security-inventory.md`, `secure-storage-abstraction-plan.md`, SDK `SdkSessionStore`, app `app_services.dart`, app config/tests | Local storage exposure is reduced: app telemetry is latest-only and blocks auth-looking strings; app auth orphan fragments are cleaned; SDK session writes omit unused refresh token; secure-storage abstractions and disabled-by-default app auth-session guardrails exist. | Real secure storage is not implemented or enabled. No secure-storage dependency or platform-backed implementation has been added, app auth tokens and SDK signed identity still use SharedPreferences by default, and no user-data migration has occurred. |

## Unresolved Items

- Certificate pinning is not implemented in the SDK or app boundary.
- TLS trust is still platform/default-library trust unless proven otherwise by a later platform/native review.
- Broker credential rotation is not addressed.
- Backend token refresh/rotation policy is not addressed.
- Real secure storage dependency is not added.
- Platform-backed secure storage is not implemented or enabled.
- App auth tokens and SDK signed identity still use SharedPreferences by default.
- Server-side authorization, broker/topic ACLs, incident authority, and relay validation remain backend-owned.
- Remote relay/LoRa manual QA is deferred and must not be treated as passed.
- `packages/eixam_connect_flutter/lib/src/realtime/*` was requested for inspection, but no such directory exists in this SDK tree; realtime code inspected lives under `packages/eixam_connect_flutter/lib/src/sdk/*realtime*`.

## Next-Action Plan

1. Keep SEC-NET implementation frozen until a specific follow-up is selected.
2. Verify MQTT WebSocket TLS behavior with the chosen MQTT client/library and document whether `wss://` receives TLS by scheme even when `client.secure` is false.
3. Decide whether certificate pinning is required for app/SDK HTTP and MQTT transports; if yes, design the platform/native impact before code changes.
4. Open backend/broker tasks for token refresh/rotation policy, broker credential rotation, broker/topic ACLs, and server-side lifecycle authority.
5. Continue secure storage Phase 3 only after approving a real platform-backed dependency and iOS/Android storage policy.
6. Run dedicated remote relay/LoRa manual QA before using that path as release evidence.

## Guardrails For Future Work

- Do not change SOS/MQTT/BLE behavior while doing documentation-only SEC-NET work.
- Do not reintroduce HTTP SOS trigger.
- Preserve HTTP cancel/read-only behavior unless a backend/API migration explicitly replaces it.
- Preserve release/profile rejection of insecure API and realtime endpoints.
- Do not claim TLS pinning, broker rotation, secure storage rollout, backend authorization, or remote relay/LoRa QA completion until those items are separately implemented and verified.
