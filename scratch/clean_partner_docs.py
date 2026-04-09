import os

# 1. Partner docs should not expose `/v1/auth/sign` as an internal validation workflow.
partner_files = [
    "docs/partner/quickstart.md",
    "docs/partner/sdk-overview.md",
    "docs/partner/backend-integration.md",
    "docs/partner/troubleshooting.md",
]

for filepath in partner_files:
    if not os.path.exists(filepath):
        continue
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    orig = content
    # In quickstart and sdk-overview:
    content = content.replace(
        "- `/v1/auth/sign` is acceptable for internal EIXAM staging validation only; partner production flows must implement the server-side signing step in the partner backend",
        "- partner production flows must implement the server-side signing step securely within the partner backend"
    )
    content = content.replace(
        "- internal EIXAM staging validation may use `/v1/auth/sign`, but partner integrations must implement the signing flow on their own backend",
        "- partner integrations must implement the signing flow securely on their own backend"
    )
    # In backend-integration:
    content = content.replace(
        "- `/v1/auth/sign` is acceptable for internal staging validation only\n- real partner integrations must implement the server-side sign flow in the partner backend",
        "- partner integrations must implement the server-side sign flow locally inside the partner backend"
    )
    content = content.replace(
        "`/v1/auth/sign` is acceptable only for internal EIXAM staging validation. Partner production systems must implement the sign flow on their own backend.",
        "Partner production systems must implement the sign flow directly on their own backend."
    )
    # In troubleshooting:
    content = content.replace(
        "- use `/v1/auth/sign` only for internal staging validation, not for partner production architecture",
        "- perform all signing entirely within the partner production backend architecture"
    )
    
    # Revert the staging URL in custom endpoint examples in partner docs:
    content = content.replace(
        "mqttUrl: 'ssl://mqtt.staging.eixam.io:8883'",
        "mqttUrl: 'ssl://partner-mqtt.example.com:8883'"
    )
    
    if content != orig:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"Cleaned internal validation references from {filepath}")
