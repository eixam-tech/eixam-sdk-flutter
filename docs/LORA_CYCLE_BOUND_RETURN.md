# Cycle-bound SDK LoRa return (local integration)

This is a new coordinated firmware/SDK contract. It is not supported by the
recorded firmware 0b8e429 or the transport-only firmware 11f3dc7. No new physical
D1 PASS is claimed. The backend fanout fix is tracked separately.

The no-fix/last-known-location enrichment must retain `originPacketId` alongside
the exact raw receipt and receipt time. Physical D1 exposed a missed copy in
that path before WEB ACK; the SDK corrects it and tests the captured E4 receipt
through the actual BLE runtime on both channels, with and without a prior fix.
This correction does not promote that stopped attempt to a return-path PASS.

The first **TX-completed TEL START mesh packet ID** identifies the origin's
current SOS cycle. Allocation/enqueue alone does not authorize a return. Zero
cannot identify a bound reply because protobuf omits zero. The firmware clears
this authority when the episode closes or a new episode opens.

On private SOS/TEL ports 259/258, upgraded origins mark `Data.bitfield & 0x10`
and put that first packet ID in the existing `Data.reply_id` on subsequent SOS
uplinks. The initial TEL START has no earlier reply reference, so the receiving
relay uses its actual `MeshPacket.id`, only if `MeshPacket.from` equals the SOS
payload origin. Forwarders preserve the reference. Bits 0/1 remain Meshtastic's
MQTT/response flags; `want_response` is not enabled and no automatic NAK is
requested. Bit 4 is a new Eixam private-port capability, not a pre-existing one.

A capable relay on PRIMARY emits this **new** BLE envelope on SOS notify:
`E4 01 <cycle u32 LE> <payload length u8> 01 <SOS payload 7 or 12 B>`.
Total 15/20 B. Legacy SOS is still observable, with `originPacketId == null`;
it cannot authorize a strict return. The SDK does not substitute the 4-bit SOS
counter, a timestamp, a truncated backend UUID, or the relay node ID.

`RemoteRelaySosSnapshot.originPacketId` retains the observed reference. The SDK
passes `lora:<origin uint32 decimal>:<packet uint32 decimal>` through the existing
MQTT request `cycleKey`. The repository already matches the canonical processed
reply to its exact pending `occurredAt`; it now retains that pending cycleKey
with the resulting backend incident UUID, including persistence/restoration.
Every bound lifecycle return must also retain that canonical occurredAt; missing
or stale canonical timestamps are rejected before local lifecycle admission.
No new backend JSON field or endpoint is introduced.

A new observed cycle cannot inherit the previous incident UUID. Both nonterminal
ACK and terminal RESOLVE/CANCEL require matching incident, origin, relay, relay
transport identity and canonical cycleKey. Successful duplicate actions coalesce.
The connected relay's local SOS state is not changed by remote command submission.

The **new** forced-CMD write is exactly 11 B:
`0B 01 <Rescue command 02 or 04> <origin u32 LE> <cycle u32 LE>`.
ACK uses Rescue04 (silence, episode stays open); RESOLVE/CANCEL use Rescue02
(close). A new opcode prevents older firmware from interpreting an extended
legacy08 write as a target-only return. New firmware rejects legacy08/0A
node-only return writes. Local07/09 and user button behavior are unchanged.

The relay validates the observed origin/cycle before queueing, captures the
context revision, and transmits the existing encrypted 9 B Rescue payload in a
normal mesh packet with `Data.reply_id = cycle`. The origin checks the exact
current cycle before any Rescue02/04 side effect, including the legacy raw
entrypoint (missing reference is rejected). Countdown/inactive/mismatched cycles
cannot be silenced or terminalized by a LoRa return. SDK wrong-cycle checks and
origin acceptance are separate requirements; neither is replaced with a TTL.

Android native classification retains the original envelope and routes remote
receipts without observing the relay's local lifecycle. iOS uses the same new
receipt validation and queues remote receipts while Dart is detached; it does
not save them as own-device SOS snapshots. Both hosts remain thin and pin the
same SDK revision. GPS absence, last-known age, and terminal UI semantics remain
SDK-owned.

Validation must include focused SDK lifecycle tests, packet/command codecs,
Android native tests, Swift receipt tests, firmware receiver/cycle tests, TAG and
GW builds, analyzers, test-fast, test-sos, test-all and host gates. These are not
RF acceptance. Commit before any physical test. D1 volume1 and immediate cleanup
remain required; D2/D3 remain gated on D1 PASS. Gateway compatibility now echoes
its captured cycle reference, but no gateway physical validation is claimed.
