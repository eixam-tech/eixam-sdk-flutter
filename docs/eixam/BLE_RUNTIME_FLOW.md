# BLE Runtime Flow

1. `RealBleClient` or `MockBleClient`
   - scan
   - connect
   - discover services
   - subscribe to TEL and SOS notify characteristics
   - write typed commands to INET or CMD

2. Protocol layer
   - `EixamTelPacket.tryParse(...)`
   - `EixamSosPacket.tryParse(...)`
   - `EixamDeviceCommand`

3. Runtime layer
   - `BleDeviceRuntimeProvider` receives characteristic-aware notifications
   - decodes them
   - emits protocol-driven incoming events
   - forwards SOS packets into `DeviceSosController`

4. Orchestration
   - `DeviceSosController` keeps only useful derived SOS state
   - `EixamConnectSdkImpl` decides whether to emit local notifications or send backend-driven BLE responses

5. UI
   - `DeviceDetailScreen` renders device state, decoded SOS details, and invokes SDK command methods
   - UI does not assemble raw BLE payloads
