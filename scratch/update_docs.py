import os
import re

files_to_check = [
    "README.md",
    "HOW_TO_RUN_PROJECT.md",
    "packages/eixam_connect_flutter/MIGRATION.md",
    "docs/partner/quickstart.md",
    "docs/partner/sdk-overview.md",
    "docs/partner/backend-integration.md",
    "docs/partner/public-api.md",
    "docs/partner/public-api-examples.md",
    "docs/partner/api-reference.md",
    "docs/partner/troubleshooting.md",
    "docs/full/sdk/overview.md",
    "docs/full/sdk/backend-integration.md",
    "docs/full/sdk/partner-integration-guide.md",
    "docs/full/sdk/public-api.md",
    "docs/full/sdk/public-api-examples.md",
    "docs/full/sdk/troubleshooting.md",
    "docs/full/api/api-reference.md",
    "docs/full/reference-app/debug-app-validation-guide.md",
    "docs/full/reference-app/real-backend-validation-checklist.md",
]

def replace_in_file(filepath):
    if not os.path.exists(filepath):
        return
    
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    orig_content = content

    # 4. Current staging transport
    # Replace ssl://partner-mqtt.example.com with ssl://mqtt.staging.eixam.io:8883 in context of staging.
    # We will replace them generally (unless explicitly examples) to modernize.
    content = content.replace("ssl://partner-mqtt.example.com:8883", "ssl://mqtt.staging.eixam.io:8883")
    
    # Remove web-socket first emphasis if present
    # Usually "websocketUrl" is fine as the field name, but let's ensure we add a note that the staging uses ssl://...
    
    # 7. Canonical hardware_id
    hardware_id_replacement = """- telemetry payloads may include `deviceId = hardware_id` of the paired device
- SOS operational payloads may also include `deviceId = hardware_id` when the SDK knows the paired device
- **Canonical hardware_id**: The backend/mobile `hardware_id` source of truth is the canonical Meshtastic/node identifier like `CF:82...`.
  - this is **NOT** the local BLE/runtime transport id
  - this is **NOT** the friendly advertised BLE name such as `Meshtastic_1aa8`
- hardware-originated SOS should send that `deviceId` when available so backend and web surfaces can display the originating hardware
- if no paired hardware id is available or if it cannot be resolved safely, `deviceId` may remain omitted"""
    
    if "telemetry payloads may include `deviceId = hardware_id`" in content and "Meshtastic/node identifier like `CF:82" not in content:
        # We find the block starting with "telemetry payloads may include" and replace it
        content = re.sub(
            r'- telemetry payloads may include `deviceId = hardware_id`.+?if no paired hardware id is available, `deviceId` may remain omitted',
            hardware_id_replacement,
            content,
            flags=re.DOTALL
        )

    # In MIGRATION.md
    if "deviceId = hardware_id" in content and "Meshtastic/node" not in content and "telemetry payloads may include" not in content:
        mig_hardware_id_replacement = """- hardware-originated SOS should send `deviceId = hardware_id` when available
- app-originated SOS without a paired device may omit `deviceId`
- telemetry keeps using `deviceId = hardware_id` when available

**Note on canonical hardware_id**: The backend/mobile `hardware_id` source of truth is the canonical Meshtastic/node identifier like `CF:82...`.
- this is **NOT** the local BLE/runtime transport id
- this is **NOT** the friendly advertised BLE name such as `Meshtastic_1aa8`
- if canonical hardware id cannot be resolved safely, we prefer omission rather than inventing a value."""
        content = re.sub(
            r'- hardware-originated SOS should send `deviceId = hardware_id` when available.+?- telemetry keeps using `deviceId = hardware_id` when available',
            mig_hardware_id_replacement,
            content,
            flags=re.DOTALL
        )

    # 10. Background behavior and reconnect (and protection)
    # Add notes about background continuity
    if "Protection Mode" in content and "background continuity" not in content:
        if "## Protection Mode\n" in content:
            content = content.replace("## Protection Mode\n", "## Protection Mode\n\nBackground continuity is far stronger on Android when Protection Mode/native foreground service owns the BLE transport. Plain Flutter-owned BLE provides no guaranteed full background runtime.\n")

    # 6. Paired-device registration flow
    # Add note in the runtime device status or registry docs
    registry_note = """
### Paired-device sync logic

- after a known device is paired/connected and the signed-session identity is ready, the SDK/runtime may attempt backend paired-device sync.
- the validation app registry card is a status/retry/debug surface, not the intended primary manual flow.
- automatic sync uses `hardware_id`, `firmware_version`, `hardware_model`, and `paired_at`.
- automatic sync is safe only when a canonical backend-compatible hardware id can be resolved.
"""
    if "## Backend Device Registry" in content and "Paired-device sync logic" not in content:
        content = content.replace("## Backend Device Registry\n", f"## Backend Device Registry\n{registry_note}\n")
    elif "7. Test Backend Device Registry" in content and "validation app registry card" not in content:
        content = content.replace("## 7. Test Backend Device Registry\n", f"## 7. Test Backend Device Registry\n{registry_note}\n")

    # Add SOS flow subscription topic clarifications
    if "sos/events/{segment}" in content:
        content = content.replace("sos/events/{segment}", "sos/events/{external_user_id}")
    if "tel/{segment}/data" in content:
        content = content.replace("tel/{segment}/data", "tel/{external_user_id}/data")

    # Save if changes made
    if content != orig_content:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"Updated {filepath}")

for f in files_to_check:
    replace_in_file(f)
