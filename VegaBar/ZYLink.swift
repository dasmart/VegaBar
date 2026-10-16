import CoreBluetooth
import Foundation

/// GATT link to one ZY light. Control frames go raw over the vendor service
/// (FEE9 / D44BC439-…600 write, …601 notify); the connected light relays
/// frames addressed to other mesh nodes.
///
/// There is no encryption and no key on FEE9.
/// The Bluetooth Mesh services (1827 provisioning, 1828 proxy) are only used
/// by `MeshController` for pairing and configuration. VegaBar scans for those
/// mesh services because that's what the lights advertise, then talks FEE9 to
/// whichever proxy it connects to.
///
/// Every outgoing frame passes through `send(_:)`, which applies the
/// `LightSafety` checks, coalesces repeats and rate-limits before anything
/// reaches the radio.
///
/// CoreBluetooth delivers delegate callbacks on the main queue (see `init`),
/// which is why the delegate methods below are plain main-actor methods.
///
/// Operational note: repeatedly force-quitting VegaBar while a connection was
/// being set up once wedged macOS's `bluetoothd`, so that nothing could
/// connect to the light. Toggling Bluetooth off and on fixed it; no code
/// change was needed.
@MainActor
final class ZYLink: NSObject {
    /// Advertised by a light that is waiting to be paired (unprovisioned).
    // CBUUID is immutable; `unsafe` only because CoreBluetooth doesn't say so.
    nonisolated(unsafe) static let meshProvisioningService = CBUUID(string: "1827")
    /// Advertised by a provisioned light (mesh proxy). ZY frames still go to FEE9
    /// on the same light, never through the proxy service.
    nonisolated(unsafe) static let meshProxyService = CBUUID(string: "1828")
    /// Zhiyun's vendor service, where all control frames go.
    nonisolated(unsafe) static let zyService = CBUUID(string: "FEE9")
    /// Write characteristic: frames are written here, normally without response.
    nonisolated(unsafe) static let zyWrite = CBUUID(string: "D44BC439-ABFD-45A2-B575-925416129600")
    /// Notify characteristic: replies and unsolicited reports arrive here.
    nonisolated(unsafe) static let zyNotify = CBUUID(string: "D44BC439-ABFD-45A2-B575-925416129601")

    /// Connection lifecycle as shown in the UI. `connected` means FEE9 is
    /// discovered and notifications are on, so frames can be sent.
    enum State: Equatable { case poweredOff, unauthorized, idle, scanning, connecting, connected }

    /// A light seen in a scan, with its advertisement kept for mesh matching.
    struct Discovered: Identifiable {
        let id: UUID
        let peripheral: CBPeripheral
        let advertisementData: [String: Any]
        var rssi: Int
        /// Prefer the GATT name, falling back to the advertised local name.
        var name: String { peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "ZY Light" }
        /// The name to show: the product name the phone app uses
        /// ("MOLUS G60_8723"), or the Bluetooth name if the code isn't known.
        var displayName: String { LightNaming.displayName(bluetoothName: name) ?? name }
        /// Service UUIDs from both the advertised list and the service-data keys.
        /// Mesh lights may carry 1827/1828 as service data rather than in the list.
        private var services: Set<CBUUID> {
            let listed = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let data = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?.keys
            return Set(listed).union(data ?? [:].keys)
        }
        /// Advertising Mesh Provisioning (1827): waiting to be paired.
        var isUnprovisioned: Bool { services.contains(ZYLink.meshProvisioningService) }
        /// Advertising Mesh Proxy (1828): already provisioned, to us or another network.
        var isMeshProxy: Bool { services.contains(ZYLink.meshProxyService) }
        var isMeshDevice: Bool { isUnprovisioned || isMeshProxy }

        /// One-line description for the debug log (RSSI, name, services, raw data).
        var logDescription: String {
            let sd = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:])
                .map { "\($0.key.uuidString)=\($0.value.hex)" }
            let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hex ?? ""
            return "\(rssi)dBm \"\(name)\" \(id) services=\(services.map(\.uuidString).sorted()) sdata=\(sd) mfg=\(mfg)"
        }
    }

    /// Fires on every state assignment, even when the state is unchanged.
    var onStateChanged: ((State) -> Void)?
    /// Fires for every advertisement (duplicates included while scanning).
    var onDiscovered: ((Discovered) -> Void)?
    /// Raw notification bytes; may hold part of a frame or several frames.
    var onFrame: ((Data) -> Void)?

    /// Set in `init`, once `self` exists to be the delegate.
    private var central: CBCentralManager!
    /// The light we're connecting or connected to. Only one link at a time.
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    /// Frames waiting to be written, oldest first.
    private var queue: [Outgoing] = []
    /// True while a with-response write is in flight (only if the light lacks
    /// write-without-response).
    private var writing = false
    /// True while a delayed `pump()` is already scheduled, so it isn't doubled.
    private var pumpScheduled = false
    /// When the last frame was written, for the global rate limit.
    private var lastSend = Date.distantPast
    /// When each command was last written, for per-command spacing.
    private var lastSendByCmd: [ZYProtocol.Cmd: Date] = [:]
    /// Remembers that a scan was requested, so it can start (or resume) once
    /// Bluetooth powers on.
    private var wantScan = false
    private var unfiltered = false
    /// Last logged description per device, so the log only gets an `adv` line
    /// when an advertisement's content changes (RSSI is ignored).
    private var logged: [UUID: String] = [:]
    private(set) var state: State = .idle {
        didSet {
            if state != oldValue { Log.info(.ble, "link \(state) \(peripheral?.name ?? "")") }
            onStateChanged?(state)
        }
    }

    /// Callbacks arrive on the main queue, matching this class's `@MainActor`.
    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        Log.info(.ble, "central created, state \(central.state.rawValue)")
    }

    /// The connected light's CoreBluetooth identifier, or nil if not connected.
    var connectedPeripheralId: UUID? { state == .connected ? peripheral?.identifier : nil }
    /// The connected light's Bluetooth name (for example "PL103_8723"), or nil.
    var connectedPeripheralName: String? { state == .connected ? peripheral?.name : nil }

    /// `unfiltered` scans every advertiser (used while pairing, and logged) in case a
    /// light's advertisement doesn't list the mesh service UUIDs where macOS filters.
    func startScan(unfiltered: Bool = false) {
        wantScan = true
        self.unfiltered = unfiltered
        guard central.state == .poweredOn else { return }
        central.stopScan()
        // Allow duplicates so RSSI stays fresh and proxies that start advertising
        // later (e.g. after a reboot) are reported again.
        central.scanForPeripherals(withServices: unfiltered ? nil : [Self.meshProvisioningService, Self.meshProxyService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        Log.info(.ble, "scan started (unfiltered: \(unfiltered))")
        if state == .idle { state = .scanning }
    }

    /// Reconnects to the light we last used without waiting for an advertisement.
    /// A light that is connected (at the system level, or to another app) doesn't
    /// advertise, so scanning alone would never find it again. A pending
    /// `connect` also completes on its own once the light comes back in range.
    /// a light that is still connected at the system level (or to another app)
    /// doesn't advertise, and a pending connect also completes once it's back.
    private func reconnectLast() {
        guard peripheral == nil,
              let s = UserDefaults.standard.string(forKey: "lastPeripheral"), let id = UUID(uuidString: s) else { return }
        // First look among peripherals the system already has connected, then
        // fall back to a plain lookup by the remembered identifier.
        let alreadyConnected = central.retrieveConnectedPeripherals(withServices: [Self.zyService, Self.meshProxyService])
        if let p = alreadyConnected.first(where: { $0.identifier == id }) ?? central.retrievePeripherals(withIdentifiers: [id]).first {
            Log.info(.ble, "reconnecting to last light \(p.name ?? id.uuidString) (system-connected: \(alreadyConnected.contains(p)))")
            connect(p)
        }
    }

    /// Stops scanning; an existing connection is unaffected.
    func stopScan() {
        wantScan = false
        if central.state == .poweredOn { central.stopScan() }
        if state == .scanning { state = .idle }
    }

    /// Connects to `p`, dropping any link to a different light first.
    /// Service discovery continues in `didConnect`.
    func connect(_ p: CBPeripheral) {
        if let current = peripheral, current.identifier != p.identifier {
            central.cancelPeripheralConnection(current)
        }
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p)
    }

    /// Drops the link and anything still queued for it.
    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeChar = nil
        queue.removeAll()
        state = .idle
    }

    // MARK: - Sending (safety-checked, coalesced, rate-limited)

    /// A frame waiting to be written, plus what's needed to coalesce and pace it.
    private struct Outgoing {
        var frame: Data
        let cmd: ZYProtocol.Cmd
        /// Frames with the same key replace each other while queued, so only the
        /// newest brightness (etc.) for a given light is ever sent.
        let key: String
        /// Writes are paced by `LightSafety.minInterval`; reads are not.
        let isWrite: Bool
    }

    /// Queues one frame for the connected light.
    ///
    /// Every frame is validated by `LightSafety` first — out-of-range values and
    /// commands VegaBar has no business sending are dropped here, whatever their
    /// source. Accepted frames are coalesced with any queued frame of the same
    /// kind and paced by `pump()`.
    @discardableResult
    func send(_ frame: Data) -> Bool {
        guard state == .connected else {
            Log.trace("tx dropped (not connected) \(frame.hex)")
            return false
        }
        if case .rejected(let reason) = LightSafety.validate(frame) {
            Log.error(.safety, "tx REJECTED by safety check (\(reason)): \(frame.hex)")
            return false
        }
        let b = [UInt8](frame)
        // cmd is at frame bytes 8-9. LightSafety already proved it's a known command.
        guard let cmd = ZYProtocol.Cmd(rawValue: UInt16(b[8]) | UInt16(b[9]) << 8) else { return false }
        // Key = command + payload header (device id and read/write flag, frame
        // bytes 10-12), i.e. "set brightness on 0x8000" vs "read brightness on
        // 0x8000". Clamped for short payloads (e.g. getDeviceId has none).
        // For 0x10xx light commands byte 12 is the read/write flag; every other
        // allowed command changes state, so it counts as a write for pacing.
        let isWrite = cmd.rawValue >> 12 == 1 ? (b.count > 12 && b[12] == 1) : true
        let headerEnd = min(b.count - 2, 13)
        let key = "\(cmd.rawValue):" + Data(b[10..<max(10, headerEnd)]).hex

        if let i = queue.firstIndex(where: { $0.key == key }) {
            queue[i].frame = frame                      // latest value wins
        } else if queue.count >= LightSafety.maxQueuedFrames {
            // Over the cap: drop rather than build a backlog (see LightSafety).
            Log.error(.safety, "tx dropped (queue full) \(frame.hex)")
            return false
        } else {
            queue.append(Outgoing(frame: frame, cmd: cmd, key: key, isWrite: isWrite))
        }
        pump()
        return true
    }

    /// Writes the next queued frame when pacing rules allow.
    ///
    /// - At most `LightSafety.maxFramesPerSecond` frames per second overall.
    /// - Commands listed in `LightSafety.minInterval` (power, identify, …) are
    ///   additionally spaced from their own previous send.
    /// - Like the phone app, frames go out as write-without-response, chunked to
    ///   the ATT payload size and paced on CoreBluetooth's flow control so the
    ///   light's receive buffer is never overrun.
    private func pump() {
        guard !writing, let p = peripheral, let c = writeChar, !queue.isEmpty else { return }
        // Prefer write-without-response, as the phone app does.
        let noResponse = c.properties.contains(.writeWithoutResponse)
        if noResponse && !p.canSendWriteWithoutResponse { return }  // resumed by peripheralIsReady

        // How long until both the global rate limit and this command's own
        // minimum spacing are satisfied. Negative means "now".
        let now = Date()
        var wait = lastSend.addingTimeInterval(1 / LightSafety.maxFramesPerSecond).timeIntervalSince(now)
        let next = queue[0]
        if let spacing = LightSafety.minInterval(for: next.cmd, isWrite: next.isWrite), let last = lastSendByCmd[next.cmd] {
            wait = max(wait, last.addingTimeInterval(spacing).timeIntervalSince(now))
        }
        if wait > 0 {
            schedulePump(after: wait)
            return
        }

        queue.removeFirst()
        lastSend = now
        if next.isWrite { lastSendByCmd[next.cmd] = now }
        Log.trace("tx \(next.frame.hex)")

        // Frames have no fragment header: a long frame is simply cut into
        // MTU-sized pieces and the light's parser stitches them back together.
        // Control frames are 10-21 bytes, so they normally go in one write.
        let type: CBCharacteristicWriteType = noResponse ? .withoutResponse : .withResponse
        let mtu = max(20, p.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < next.frame.count {
            p.writeValue(next.frame.subdata(in: offset..<min(offset + mtu, next.frame.count)), for: c, type: type)
            offset += mtu
        }
        // No completion callback for unacknowledged writes, so pace the next
        // frame by time (CoreBluetooth's flow control is checked at the top).
        if noResponse {
            if !queue.isEmpty { schedulePump(after: 1 / LightSafety.maxFramesPerSecond) }
        } else {
            writing = true  // resumed by didWriteValueFor
        }
    }

    /// Runs `pump()` again after `delay`, at most one pending call at a time.
    private func schedulePump(after delay: TimeInterval) {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.pumpScheduled = false
            self?.pump()
        }
    }
}

// The central is created with `queue: .main`, so CoreBluetooth delivers every
// callback on the main thread. With `@preconcurrency import CoreBluetooth` the
// delegate methods can therefore be ordinary main-actor methods; the runtime
// checks the thread on entry, so a misconfigured queue would fail loudly.
extension ZYLink: @preconcurrency CBCentralManagerDelegate {
    /// Bluetooth power / permission changes. Also the first callback after
    /// `init`: nothing can be done with the central until it reports
    /// `.poweredOn`, so a scan requested earlier starts here.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Log.info(.ble, "bluetooth state \(central.state.rawValue) authorization \(CBManager.authorization.rawValue)")
        switch central.state {
        case .poweredOn:
            state = .idle
            if wantScan { startScan(unfiltered: unfiltered) }
            // The last light may already be connected and silent; see `reconnectLast`.
            reconnectLast()
        case .unauthorized:
            state = .unauthorized
        default:
            state = .poweredOff
        }
    }

    /// Every advertisement while scanning. Logged when its content changes, then
    /// passed to `AppModel`, which decides whether to connect.
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let d = Discovered(id: peripheral.identifier, peripheral: peripheral,
                           advertisementData: advertisementData, rssi: RSSI.intValue)
        // Strip the RSSI so a changing signal level alone doesn't re-log.
        let desc = d.logDescription.replacingOccurrences(of: "-?\\d+dBm ", with: "", options: .regularExpression)
        if logged.count > 256 { logged.removeAll() }   // bounded: unfiltered scans see many devices
        if logged[d.id] != desc {
            logged[d.id] = desc
            Log.trace("adv \(d.logDescription)")
        }
        onDiscovered?(d)
    }

    /// GATT link is up; look for the ZY vendor service next.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.zyService])
    }

    /// The connect attempt failed; go back to idle so discovery can try again.
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral.identifier == self.peripheral?.identifier { self.peripheral = nil; state = .idle }
    }

    /// The link dropped (out of range, light turned off, or we cancelled).
    /// Anything still queued is stale, so it's discarded. If a scan is wanted,
    /// AppModel reconnects when the light advertises again.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        writeChar = nil
        writing = false
        queue.removeAll()
        self.peripheral = nil
        state = wantScan ? .scanning : .idle
    }
}

extension ZYLink: @preconcurrency CBPeripheralDelegate {
    /// No FEE9 service means this isn't a light we can control; give up on it.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Log.info(.ble, "services \(peripheral.services?.map(\.uuid.uuidString) ?? []) error \(error?.localizedDescription ?? "none")")
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.zyService }) else {
            disconnect()
            return
        }
        peripheral.discoverCharacteristics([Self.zyWrite, Self.zyNotify], for: service)
    }

    /// Remember the write characteristic and subscribe to the notify one.
    /// The link only counts as connected once notifications are on.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            Log.info(.ble, "char \(c.uuid.uuidString) properties 0x\(String(c.properties.rawValue, radix: 16))")
            if c.uuid == Self.zyWrite { writeChar = c }
            if c.uuid == Self.zyNotify { peripheral.setNotifyValue(true, for: c) }
        }
    }

    /// Notifications are on: the link is usable. Remember this light so
    /// `reconnectLast()` can reach it directly next time.
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { Log.error(.ble, "notify enable failed: \(error.localizedDescription)") }
        if characteristic.uuid == Self.zyNotify, writeChar != nil {
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastPeripheral")
            state = .connected
        }
    }

    /// Incoming notification. Passed on raw: `ZYProtocol.Parser` reassembles frames.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Self.zyNotify, let value = characteristic.value {
            Log.trace("rx \(value.hex)")
            onFrame?(value)
        }
    }

    /// CoreBluetooth's write-without-response buffer has room again.
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pump()
    }

    /// A with-response write finished (fallback path); send the next frame.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        pump()
    }
}

/// Lowercase hex without separators, for logging frames.
extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
