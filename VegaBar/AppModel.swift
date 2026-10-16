import CoreBluetooth
import Foundation
import NordicMesh
import Observation

/// One paired light, as the UI sees it.
struct Light: Identifiable, Hashable {
    /// The mesh node's UUID, assigned by the nRF library at provisioning.
    let id: UUID
    var name: String
    /// Mesh unicast address. Not used for control; ZY frames address lights by
    /// `zyId`, which is a separate number.
    let address: UInt16
    /// ZY device id assigned at registration (0x8000 and up). Nil until the
    /// light has been registered, in which case no command can target it yet.
    let zyId: UInt16?
}

/// The app's state and the actions behind every control surface (menu, hotkeys,
/// Shortcuts, CLI, URLs, automations). Owns the Bluetooth link and the mesh
/// controller, and is the only thing that talks to either.
///
/// `AppModel.shared` is the app's instance; the initializer takes its
/// collaborators so tests can build an isolated model with a temporary store
/// and preferences.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: - State

    /// Paired lights, derived from the mesh network plus `LightStore`.
    var lights: [Light] = []
    /// The light the controls act on; persisted so it survives relaunch.
    var selectedId: UUID? { didSet { defaults.set(selectedId?.uuidString, forKey: "selected") } }

    /// Live control state for the selected light. `isOn`, `brightness` and
    /// `cct` are set optimistically when a command is sent and corrected when
    /// the light replies to the read that follows.
    var isOn = true
    var brightness: Double = 50       // percent
    var cct: Double = 5600            // Kelvin
    var cctRange: ClosedRange<Double> = 2700...6500
    /// Battery percent from the light's voltage reply (nil if unknown / mains).
    var battery: Int?

    /// Connection and pairing state for the UI.
    var linkState: ZYLink.State = .idle
    var unprovisioned: [ZYLink.Discovered] = []
    /// Mesh lights seen while pairing that belong to another network (e.g. the phone's).
    var foreignLights: [ZYLink.Discovered] = []
    /// Progress or error text shown in the pairing section.
    var pairingStatus: String?
    var isPairing = false
    /// A problem the user should know about, shown as a dismissible banner.
    var notice: String?

    /// Called when the user (not an automation) changes colour temperature.
    var onManualColorTemp: (() -> Void)?
    /// Called on every connect, so automations can re-apply state.
    var onConnected: (() -> Void)?

    // MARK: - Collaborators

    private let link: ZYLink
    private let mesh: MeshController
    private var store: LightStore
    private let prefs: Preferences
    private let defaults: UserDefaults

    /// Coalesce slider and scroll updates; see `Throttle`. Brightness and colour
    /// temperature each get their own, so changing one never cancels a pending
    /// update of the other (e.g. a preset setting both back to back).
    private var brightnessThrottle = Throttle(interval: 0.08)
    private var colorTempThrottle = Throttle(interval: 0.08)
    /// Reassembles notification chunks into frames.
    private var parser = ZYProtocol.Parser()
    private var verifyPowerTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    /// The peripheral being paired; reconnected to for registration afterwards,
    /// because a connected light doesn't advertise.
    private var pairingPeripheral: CBPeripheral?
    /// Light awaiting its `register` frame once our FEE9 link to it is up.
    private var pendingRegistration: (node: UUID, id: UInt16)?

    init(link: ZYLink = ZYLink(), mesh: MeshController = MeshController(),
         store: LightStore = LightStore(), prefs: Preferences = .shared,
         defaults: UserDefaults = .standard) {
        self.link = link
        self.mesh = mesh
        self.store = store
        self.prefs = prefs
        self.defaults = defaults
        Log.info(.app, "app model init")
        if let s = defaults.string(forKey: "selected") { selectedId = UUID(uuidString: s) }
        notice = mesh.loadProblem
        reloadLights()
        link.onStateChanged = { [weak self] in self?.linkStateChanged($0) }
        link.onDiscovered = { [weak self] in self?.discovered($0) }
        link.onFrame = { [weak self] in self?.received($0) }
        mesh.onStepChanged = { [weak self] in self?.pairingStepChanged($0) }
        mesh.onSaveFailed = { [weak self] in self?.notice = $0 }
        link.startScan()
    }

    var selected: Light? { lights.first { $0.id == selectedId } ?? lights.first }
    var isConnected: Bool { linkState == .connected }
    /// True when the selected light can actually be addressed.
    var canControl: Bool { isConnected && selected?.zyId != nil }

    // MARK: - Controls

    /// Sends the power command, then re-reads so the switch follows the light
    /// even if a write is lost. (0x1008 is "enable": 1 = on, 0 = off.)
    func setPower(_ on: Bool) {
        isOn = on
        guard let id = selected?.zyId else { return }
        link.send(ZYProtocol.setPower(device: id, on: on))
        verifyPowerTask?.cancel()
        verifyPowerTask = Task { @MainActor [weak self] in
            // Power writes are spaced ≥1 s by LightSafety, so read back a little
            // after the write can have gone out.
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.link.send(ZYProtocol.getPower(device: id))
        }
    }

    func setBrightness(_ value: Double) {
        brightness = min(max(value, 0), 100)
        let value = brightness
        guard let id = selected?.zyId else { return }
        brightnessThrottle.run { [link] in link.send(ZYProtocol.setBrightness(device: id, percent: Float(value))) }
    }

    func setCCT(_ value: Double, byAutomation: Bool = false) {
        cct = min(max(value, cctRange.lowerBound), cctRange.upperBound)
        if !byAutomation { onManualColorTemp?() }
        let value = cct
        guard let id = selected?.zyId else { return }
        colorTempThrottle.run { [link] in link.send(ZYProtocol.setColorTemp(device: id, kelvin: Int(value.rounded()))) }
    }

    /// Makes the light blink so you can tell which one it is.
    func identify() {
        guard let id = selected?.zyId else { return }
        link.send(ZYProtocol.identify(device: id))
    }

    // MARK: - Async API (Shortcuts, CLI, automations)

    /// Waits for the light link, starting a scan if needed. Returns true only
    /// when a registered light is connected, i.e. commands will actually go out.
    func waitUntilConnected(timeout: Duration = .seconds(12)) async -> Bool {
        if canControl { return true }
        link.startScan()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
            if canControl { return true }
        }
        return canControl
    }

    /// Re-reads power, brightness and colour temperature from the light and
    /// gives the replies time to arrive, so callers can report real state.
    func refresh() async {
        refreshState()
        try? await Task.sleep(for: .milliseconds(450))
    }

    func select(_ light: Light) {
        selectedId = light.id
        refreshState()
    }

    /// Renames a light in VegaBar's records (the light's own name is unchanged).
    func rename(_ light: Light, to name: String) {
        guard let node = mesh.pairedNodes.first(where: { $0.uuid == light.id }) else { return }
        mesh.rename(node: node, to: name)
        reloadLights()
    }

    // MARK: - Pairing

    func startPairing() {
        isPairing = true
        unprovisioned.removeAll()
        foreignLights.removeAll()
        pairingStatus = "Searching for lights in pairing mode…"
        Log.info(.pairing, "pairing: started")
        // Unfiltered so lights whose advertisement lists the mesh service only in
        // service data (where macOS's UUID filter doesn't look) are still seen.
        link.startScan(unfiltered: true)
    }

    /// Leaves pairing mode (cancelling any pairing in progress) and returns to
    /// the normal filtered scan.
    func stopPairing() {
        isPairing = false
        pairingStatus = nil
        mesh.cancelPairing()
        link.startScan()
    }

    func pair(_ device: ZYLink.Discovered) {
        // Release our own GATT link so the provisioning bearer owns the radio link.
        link.disconnect()
        pairingPeripheral = device.peripheral
        mesh.pair(peripheral: device.peripheral, advertisementData: device.advertisementData)
    }

    enum UnpairResult: Equatable {
        /// The light was told to leave the network and has been forgotten.
        case removed
        /// Only VegaBar's record was removed; the light still holds its pairing.
        case forgottenOnly(reason: String)
    }

    /// Tells the light to leave the network (the same command the phone app
    /// sends), then forgets it locally.
    ///
    /// A light that isn't connected can't be told anything, so this first waits
    /// briefly for a connection. If none comes, the record is removed anyway —
    /// the user asked for that — but the result says the light itself still
    /// believes it is paired and will need a factory reset.
    func unpair(_ light: Light) async -> UnpairResult {
        var result = UnpairResult.removed
        if let id = light.zyId, selected?.id == light.id, await waitUntilConnected(timeout: .seconds(6)) {
            if !link.send(ZYProtocol.removeDevice(device: id)) {
                result = .forgottenOnly(reason: "The unpair command couldn't be sent. \(light.name) still holds its pairing and will need a factory reset.")
            } else {
                // Give the frame time to leave before the link drops.
                try? await Task.sleep(for: .milliseconds(500))
            }
        } else {
            result = .forgottenOnly(reason: light.zyId == nil
                ? "\(light.name) was never registered, so it couldn't be told to unpair. Factory-reset it before pairing again."
                : "\(light.name) wasn't reachable, so it was only forgotten here. It still holds its pairing: factory-reset it before pairing again.")
        }
        store.remove(light.id)
        if let node = mesh.pairedNodes.first(where: { $0.uuid == light.id }) { mesh.forget(node: node) }
        if selectedId == light.id { selectedId = nil }
        reloadLights()
        if lights.isEmpty { link.disconnect() }
        Log.info(.pairing, "unpaired \(light.name): \(result)")
        return result
    }

    // MARK: - Internals

    private func reloadLights() {
        lights = mesh.pairedNodes.map {
            Light(id: $0.uuid, name: $0.name ?? "Light \(String(format: "%04X", $0.primaryUnicastAddress))",
                  address: $0.primaryUnicastAddress, zyId: store.zyId(for: $0.uuid))
        }
    }

    private func linkStateChanged(_ s: ZYLink.State) {
        linkState = s
        guard s == .connected else { return }
        if let pending = pendingRegistration {
            // Final pairing step (what the phone app calls "register"): give the
            // light its ZY device id and put it in the default group.
            link.send(ZYProtocol.register(device: pending.id))
            store.setZyId(pending.id, for: pending.node)
            pendingRegistration = nil
            reloadLights()
            pairingStatus = "Paired."
            isPairing = false
        }
        ensureDeviceId()
        refreshState()
        startBatteryPolling()
        onConnected?()
    }

    private func startBatteryPolling() {
        batteryTask?.cancel()
        batteryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self, self.isConnected, let id = self.selected?.zyId {
                    self.link.send(ZYProtocol.getVoltage(device: id))
                }
                // A loose tolerance lets the system batch this with other timers.
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(15))
            }
        }
    }

    /// Lights whose pairing was interrupted after mesh provisioning have no ZY
    /// device id, so no command can address them. Ask the connected light for
    /// its id; adopt it if it has one (`received` handles the reply), otherwise
    /// register it now. Assumes the connected light is the selected one, which
    /// holds with a single light.
    private func ensureDeviceId() {
        link.send(ZYProtocol.getDeviceId())
        guard let light = selected, light.zyId == nil else { return }
        Log.info(.pairing, "light \(light.name) has no device id; probing")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isConnected, let l = self.selected, l.id == light.id, l.zyId == nil else { return }
            Log.info(.pairing, "no usable device id reply; registering")
            self.registerSelected()
        }
    }

    private func nextFreeDeviceId() -> UInt16 {
        let used = store.usedDeviceIds
        return (ZYProtocol.firstDeviceId...0xFFFE).first { !used.contains($0) } ?? ZYProtocol.firstDeviceId
    }

    private func registerSelected() {
        guard let light = selected, light.zyId == nil else { return }
        let id = nextFreeDeviceId()
        link.send(ZYProtocol.register(device: id))
        store.setZyId(id, for: light.id)
        Log.info(.pairing, "registered \(light.name) as \(String(format: "0x%04X", id))")
        reloadLights()
        refreshState()
    }

    private func refreshState() {
        guard let id = selected?.zyId, isConnected else { return }
        link.send(ZYProtocol.getBrightness(device: id))
        link.send(ZYProtocol.getColorTemp(device: id))
        link.send(ZYProtocol.getPower(device: id))
    }

    private func discovered(_ d: ZYLink.Discovered) {
        guard d.isMeshDevice else { return }   // unfiltered pairing scan: everything else is noise
        if d.isUnprovisioned {
            guard isPairing else { return }
            upsert(d, into: &unprovisioned)
            foreignLights.removeAll { $0.id == d.id }
            return
        }
        // A provisioned proxy: connect if it belongs to our network and we're idle.
        guard mesh.isKnownNode(networkIdentityAdvertisement: d.advertisementData) else {
            if isPairing { upsert(d, into: &foreignLights) }
            return
        }
        if linkState == .scanning || linkState == .idle, !mesh.isBusy {
            link.connect(d.peripheral)
        }
    }

    private func upsert(_ d: ZYLink.Discovered, into list: inout [ZYLink.Discovered]) {
        if let i = list.firstIndex(where: { $0.id == d.id }) { list[i].rssi = d.rssi } else { list.append(d) }
    }

    /// Applies replies from the light. Only replies for the selected light's id
    /// update the controls; the device-id reply drives registration recovery.
    private func received(_ data: Data) {
        let selectedZyId = selected?.zyId
        for reply in parser.feed(data) {
            switch reply {
            case .brightness(let id, let v) where id == selectedZyId: brightness = Double(v)
            case .colorTemp(let id, let k) where id == selectedZyId:
                cct = min(max(Double(k), cctRange.lowerBound), cctRange.upperBound)
            case .power(let id, let on) where id == selectedZyId: isOn = on
            case .voltage(let id, let percent) where id == selectedZyId:
                // The PL103 reports 101 for "unknown" (mains power).
                battery = (0...100).contains(percent) ? percent : nil
            case .deviceId(let id):
                Log.info(.pairing, "connected light reports device id \(String(format: "0x%04X", id))")
                if let l = lights.first(where: { $0.zyId == id }) {
                    // Default the selection to the light we're physically connected to.
                    if selectedId == nil { select(l) }
                } else if let l = selected, l.zyId == nil {
                    if id >= ZYProtocol.firstDeviceId {
                        // Registered by someone (perhaps an interrupted earlier run):
                        // adopt the id rather than re-registering.
                        store.setZyId(id, for: l.id)
                        Log.info(.pairing, "adopted device id for \(l.name)")
                        reloadLights()
                        refreshState()
                    } else {
                        // 0x0000: provisioned but never registered.
                        registerSelected()
                    }
                }
            default: break
            }
        }
    }

    private func pairingStepChanged(_ step: MeshController.PairingStep) {
        switch step {
        case .idle: pairingStatus = nil
        case .connecting: pairingStatus = "Connecting…"
        case .identifying: pairingStatus = "Identifying (the light should blink)…"
        case .provisioning: pairingStatus = "Exchanging keys…"
        case .configuring(let s): pairingStatus = s
        case .done(let address):
            reloadLights()
            guard let node = mesh.pairedNodes.first(where: { $0.primaryUnicastAddress == address }) else { break }
            if node.name == nil, let name = pairingPeripheral?.name { mesh.rename(node: node, to: name) }
            selectedId = node.uuid
            pendingRegistration = (node.uuid, nextFreeDeviceId())
            pairingStatus = "Registering light…"
            link.startScan()
            // The light is connected (to us, via the mesh bearer just closed) so it
            // won't advertise; connect straight back to it for the register step.
            if let p = pairingPeripheral { link.connect(p) }
        case .failed(let message):
            reloadLights()
            pairingStatus = message
            link.startScan()
        }
    }
}

/// Coalesces rapid slider updates so the light's command queue isn't flooded;
/// the last value always gets sent.
///
/// Leading-edge plus trailing-edge: a call more than `interval` after the last
/// immediate send runs at once; calls in between replace one another and the
/// latest runs `interval` later. `ZYLink` coalesces again in its own queue.
///
/// Use one `Throttle` per value: a shared one would let a change to one value
/// cancel the other's deferred update.
@MainActor
struct Throttle {
    let interval: TimeInterval
    private var last = Date.distantPast
    /// The trailing-edge work, cancelled whenever a newer call arrives.
    private var pending: Task<Void, Never>?

    init(interval: TimeInterval) { self.interval = interval }

    mutating func run(_ work: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let now = Date()
        if now.timeIntervalSince(last) >= interval {
            last = now
            work()
        } else {
            let delay = interval
            pending = Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                work()
            }
        }
    }
}
