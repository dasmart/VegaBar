import CoreBluetooth
import Foundation
import os
@preconcurrency import NordicMesh

/// Owns the Bluetooth Mesh network this Mac uses as provisioner, and runs the
/// pairing ("register") flow the ZY Vega app performs:
/// identify → provision (No OOB) → Composition Get → Default TTL Get →
/// Network Transmit Set(2, 1) → AppKey Add.
///
/// The ZY "register" step itself (assigning the device id with frame 0x0006)
/// isn't a mesh message; `AppModel` sends it over FEE9 once this flow reports
/// `.done`. Mesh is used only here, for provisioning and configuration:
/// day-to-day control never goes through it.
///
/// The Mac runs its own mesh network, so a light already paired to the phone
/// has to be reset before it can join this one.
@MainActor
final class MeshController: NSObject {
    /// Pairing progress, reported through `onStepChanged` to drive the UI text.
    enum PairingStep: Equatable {
        case idle
        /// Opening the provisioning (PB-GATT) link.
        case connecting
        /// Link open; the light is asked to blink while capabilities are exchanged.
        case identifying
        /// Key exchange and provisioning data transfer.
        case provisioning
        /// Post-provisioning config messages over the proxy; the text names the step.
        case configuring(String)
        /// Provisioned and configured; carries the node's unicast address.
        case done(Address)
        case failed(String)
    }

    /// NordicMesh's network manager: keys, nodes, and the config message layer.
    let manager: MeshNetworkManager
    /// Set when an existing pairing file couldn't be read at launch (see
    /// `loadOrCreateNetwork`); the UI shows it once.
    private(set) var loadProblem: String?
    /// Called when the network can't be written to disk — a failure that would
    /// otherwise silently lose the pairing.
    var onSaveFailed: ((String) -> Void)?
    var onStepChanged: ((PairingStep) -> Void)?

    /// Provisioning bearer (service 1827), open only until provisioning completes.
    private var pbBearer: PBGattBearer?
    /// Proxy bearer (service 1828), open only for the configuration messages.
    private var proxyBearer: GattBearer?
    private var provisioningManager: ProvisioningManager?
    /// The peripheral being paired. The proxy bearer reconnects to it by identifier
    /// after the light reboots.
    private var pairingPeripheralId: UUID?
    /// Fails the pairing if the light never identifies itself as a proxy.
    private var proxyWaitTask: Task<Void, Never>?
    /// True once the config messages have started, so they're sent only once.
    private var configStarted = false
    /// Set once provisioning completes. Its presence tells `bearer(_:didClose:)`
    /// that the provisioning link closing is expected, not a failure.
    private var provisionedAddress: Address?

    private(set) var step: PairingStep = .idle {
        didSet { Log.info(.pairing, "pairing step: \(step)"); onStepChanged?(step) }
    }

    /// Sets the mesh network parameters (default TTL 5 and the segment /
    /// acknowledgement timeouts) and loads or creates the stored network.
    override init() {
        manager = MeshNetworkManager(using: AppSupportStorage())
        manager.networkParameters = .basic { p in
            p.setDefaultTtl(5)
            p.discardIncompleteSegmentedMessages(after: 10.0)
            p.retransmitAcknowledgedMessage(after: 4.2)
            p.discardAcknowledgedMessages(after: 40.0)
        }
        super.init()
        manager.logger = self
        // Tells us when the connected proxy has been identified (see `proxyReady`).
        manager.proxyFilter.delegate = self
        loadOrCreateNetwork()
        // Creates the Mac's own mandatory models (Configuration Client among
        // them). NordicMesh requires this after every load or create, even with
        // no custom models: without it no local model can decode the light's
        // config replies, so they arrive as unknown messages and the awaiting
        // send never completes.
        manager.localElements = []
    }

    // MARK: - Network

    /// Loads the saved network, or creates a fresh one named "VegaBar" with this
    /// Mac as provisioner and a random application key (needed for AppKey Add).
    private func loadOrCreateNetwork() {
        let fileExisted = FileManager.default.fileExists(atPath: AppSupportStorage.fileURL.path)
        if (try? manager.load()) == true, manager.meshNetwork != nil { return }
        if fileExisted {
            // Never silently replace a network we failed to read: that would orphan
            // every paired light. Keep the file for inspection and tell the user.
            let backup = AppSupportStorage.directory
                .appendingPathComponent("MeshNetwork.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: AppSupportStorage.fileURL, to: backup)
            Log.error(.storage, "MeshNetwork.json couldn't be read; moved to \(backup.lastPathComponent)")
            loadProblem = "The pairing file couldn't be read, so VegaBar started a new network. The old file was kept as \(backup.lastPathComponent). Your light will need a factory reset before it can be paired again."
        }
        let host = Host.current().localizedName ?? "Mac"
        _ = manager.createNewMeshNetwork(withName: "VegaBar", by: host)
        if let network = manager.meshNetwork, network.applicationKeys.isEmpty {
            _ = try? network.add(applicationKey: Data.random128BitKey(), name: "App Key 1")
        }
        saveNetwork()
    }

    /// Saves the network and reports failure instead of swallowing it.
    @discardableResult
    func saveNetwork() -> Bool {
        let ok = manager.save()
        if !ok {
            Log.error(.storage, "couldn't save MeshNetwork.json")
            onSaveFailed?("Couldn't save the pairing data to Application Support. Check free disk space and permissions.")
        }
        return ok
    }

    /// Lights this Mac has paired, excluding the Mac's own provisioner node.
    var pairedNodes: [Node] {
        guard let network = manager.meshNetwork else { return [] }
        let localUUID = network.localProvisioner?.node?.uuid
        return network.nodes.filter { $0.uuid != localUUID }
    }

    /// True if a proxy advertisement belongs to our network. Proxies advertise
    /// either a Network Identity or a Node Identity, both derived from our keys,
    /// so this tells our lights apart from ones paired to the phone.
    func isKnownNode(networkIdentityAdvertisement advertisementData: [String: Any]) -> Bool {
        guard let network = manager.meshNetwork else { return false }
        if let id = advertisementData.networkIdentity, network.matches(networkIdentity: id) { return true }
        if let id = advertisementData.nodeIdentity, network.matches(nodeIdentity: id) { return true }
        return false
    }

    /// Sets the node's display name in VegaBar's mesh database (not on the light).
    func rename(node: Node, to name: String) {
        node.name = name
        saveNetwork()
    }

    /// Removes the node from this Mac's network. The caller is responsible for
    /// telling the light itself to reset (ZY removeDevice frame).
    func forget(node: Node) {
        manager.meshNetwork?.remove(node: node)
        saveNetwork()
    }

    // MARK: - Pairing

    /// Starts pairing an unprovisioned light. Progress is reported through `step`.
    func pair(peripheral: CBPeripheral, advertisementData: [String: Any]) {
        // Ignore a second tap while a pairing is already running.
        guard step == .idle || isTerminal(step) else { return }
        guard let device = UnprovisionedDevice(advertisementData: advertisementData) else {
            step = .failed("Not an unprovisioned mesh device")
            return
        }
        device.name = peripheral.name ?? device.name
        pairingPeripheralId = peripheral.identifier
        provisionedAddress = nil
        step = .connecting

        let bearer = PBGattBearer(target: peripheral)
        bearer.delegate = self
        bearer.logger = self
        pbBearer = bearer
        do {
            provisioningManager = try manager.provision(unprovisionedDevice: device, over: bearer)
            provisioningManager?.delegate = self
            bearer.open()
        } catch {
            fail("Could not start pairing: \(error.localizedDescription)")
        }
    }

    /// Abandons any pairing in progress and closes both bearers.
    func cancelPairing() {
        proxyWaitTask?.cancel()
        proxyWaitTask = nil
        pbBearer?.close()
        proxyBearer?.close()
        pbBearer = nil
        proxyBearer = nil
        provisioningManager = nil
        step = .idle
    }

    /// True while a pairing is in progress; `AppModel` won't auto-connect then.
    var isBusy: Bool { !(step == .idle || isTerminal(step)) }

    /// `done` and `failed` end a pairing; a new one may start after either.
    private func isTerminal(_ s: PairingStep) -> Bool {
        switch s {
        case .done, .failed: return true
        default: return false
        }
    }

    /// Closes both bearers and reports the failure.
    private func fail(_ message: String) {
        proxyWaitTask?.cancel()
        proxyWaitTask = nil
        pbBearer?.close()
        proxyBearer?.close()
        pbBearer = nil
        proxyBearer = nil
        step = .failed(message)
    }

    /// After provisioning, the light reboots and advertises the Mesh Proxy
    /// service; connect to it and push the configuration the Android app sends.
    private func connectProxyForConfiguration() {
        guard let id = pairingPeripheralId else { return }
        configStarted = false
        step = .configuring("Connecting to light…")
        // Connect by peripheral identifier rather than by scanning for the
        // proxy advertisement.
        let bearer = GattBearer(targetWithIdentifier: id)
        bearer.delegate = self
        bearer.logger = self
        // Config messages go out (and responses come back) through this bearer.
        bearer.dataDelegate = manager
        manager.transmitter = bearer
        proxyBearer = bearer
        bearer.open()
    }

    /// The proxy link is open, but NordicMesh refuses to send to the light until
    /// it has identified it as a proxy: the light sends a network beacon, the
    /// library sets up the proxy filter, and the light answers. Sending before
    /// that fails with "No GATT Proxy Node is connected". So wait for the
    /// filter's answer (`proxyReady`), giving up after 15 s.
    private func waitForProxyThenConfigure() {
        step = .configuring("Waiting for light…")
        if manager.proxyFilter.proxy != nil {
            configure()
            return
        }
        proxyWaitTask?.cancel()
        proxyWaitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, !self.configStarted, self.proxyBearer != nil else { return }
            self.fail("The light didn't respond after pairing. Turn it off and on, then try again.")
        }
    }

    /// Called when the proxy filter reports back, which means the connected
    /// light is now known to NordicMesh as a proxy and config messages can go.
    fileprivate func proxyReady() {
        guard proxyBearer != nil, !configStarted, case .configuring = step,
              manager.proxyFilter.proxy != nil else { return }
        Log.info(.pairing, "proxy identified; configuring")
        configure()
    }

    /// Sends the configuration the Android app sends after provisioning, one
    /// acknowledged message at a time, then closes the proxy link and reports
    /// `.done`. `AppModel` then reconnects over FEE9 to register the device id.
    private func configure() {
        guard let address = provisionedAddress,
              let node = manager.meshNetwork?.node(withAddress: address),
              let appKey = manager.meshNetwork?.applicationKeys.first else {
            fail("Provisioned node missing")
            return
        }
        configStarted = true
        proxyWaitTask?.cancel()
        proxyWaitTask = nil
        Task { @MainActor in
            do {
                step = .configuring("Reading composition…")
                _ = try await send(ConfigCompositionDataGet(), to: node)
                step = .configuring("Reading default TTL…")
                _ = try await send(ConfigDefaultTtlGet(), to: node)
                step = .configuring("Setting network transmit…")
                // Same Network Transmit values (count 2, steps 1) as the phone app.
                _ = try await send(ConfigNetworkTransmitSet(count: 2, steps: 1), to: node)
                step = .configuring("Adding application key…")
                _ = try await send(ConfigAppKeyAdd(applicationKey: appKey), to: node)
                saveNetwork()
                proxyBearer?.close()
                proxyBearer = nil
                manager.transmitter = nil
                step = .done(address)
            } catch {
                // Provisioning already succeeded; the light is in our network even
                // if a config step timed out, so keep it and report the problem.
                saveNetwork()
                fail("Configuration failed: \(error.localizedDescription)")
            }
        }
    }

    /// Bridges NordicMesh's callback-based acknowledged send into async/await.
    /// The callback fires with the light's status message, or an error on timeout.
    ///
    /// NordicMesh's own timeout stops once a reply arrives, even one it can't
    /// deliver, so VegaBar keeps its own: after `timeout` the send fails rather
    /// than leaving pairing stuck. Whichever comes first resumes; the other is
    /// ignored.
    private func send(_ message: AcknowledgedConfigMessage, to node: Node,
                      timeout: Duration = .seconds(20)) async throws -> ConfigResponse {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { cont in
            @Sendable func finish(_ result: Result<ConfigResponse, Error>) {
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { cont.resume(with: result) }
            }
            do {
                try manager.send(message, to: node) { finish($0) }
            } catch {
                finish(.failure(error))
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                finish(.failure(ConfigTimeout()))
            }
        }
    }
}

/// The light didn't answer a pairing configuration message in time.
struct ConfigTimeout: LocalizedError {
    var errorDescription: String? { "The light didn't answer in time." }
}

// MARK: - Bearer delegate

extension MeshController: GattBearerDelegate {
    /// A bearer is open: start identify on the provisioning link, or the
    /// config messages on the proxy link.
    nonisolated func bearerDidOpen(_ bearer: Bearer) {
        Task { @MainActor in
            if bearer === self.pbBearer {
                self.step = .identifying
                // Provisioning Invite with a 5 s attention timer: the light blinks.
                do { try self.provisioningManager?.identify(andAttractFor: 5) } catch {
                    self.fail("Identify failed: \(error.localizedDescription)")
                }
            } else if bearer === self.proxyBearer {
                self.waitForProxyThenConfigure()
            }
        }
    }

    /// A bearer closed. For the provisioning bearer after `.complete` this is the
    /// normal hand-off to the proxy bearer; any other close mid-pairing is a failure.
    nonisolated func bearer(_ bearer: Bearer, didClose error: Error?) {
        Task { @MainActor in
            if bearer === self.pbBearer {
                self.pbBearer = nil
                if self.provisionedAddress != nil {
                    // Expected: the light drops the provisioning link and reboots.
                    // Give it a moment to come back up as a proxy before connecting.
                    try? await Task.sleep(for: .seconds(2))
                    self.connectProxyForConfiguration()
                } else if !self.isTerminal(self.step) && self.step != .idle {
                    self.fail("Light disconnected during pairing")
                }
            } else if bearer === self.proxyBearer, case .configuring = self.step {
                self.fail("Light disconnected during configuration")
            }
        }
    }
}

// MARK: - Proxy filter delegate

extension MeshController: ProxyFilterDelegate {
    /// Fires for every Filter Status from the proxy, including the first one,
    /// which is when NordicMesh records the connected proxy.
    nonisolated func proxyFilterUpdated(type: ProxyFilerType, addresses: Set<Address>) {
        Task { @MainActor in self.proxyReady() }
    }
}

// MARK: - Provisioning delegate

extension MeshController: ProvisioningDelegate {
    nonisolated func authenticationActionRequired(_ action: AuthAction) {
        // ZY lights use No OOB; nothing to do.
    }

    nonisolated func inputComplete() {}

    /// Provisioning state machine. After the light reports its capabilities we
    /// provision with the strongest algorithm and No OOB, as the phone app
    /// does. On `.complete` the node is saved and the provisioning
    /// link closed, which triggers the proxy configuration step.
    nonisolated func provisioningState(of unprovisionedDevice: UnprovisionedDevice,
                                       didChangeTo state: ProvisioningState) {
        Task { @MainActor in
            switch state {
            case .capabilitiesReceived(let capabilities):
                self.step = .provisioning
                do {
                    try self.provisioningManager?.provision(
                        usingAlgorithm: capabilities.algorithms.strongest,
                        publicKey: .noOobPublicKey,
                        authenticationMethod: .noOob)
                } catch {
                    self.fail("Provisioning refused: \(error.localizedDescription)")
                }
            case .complete:
                self.provisionedAddress = self.provisioningManager?.unicastAddress
                self.saveNetwork()
                self.pbBearer?.close()
            case .failed(let error):
                self.fail("Provisioning failed: \(error.localizedDescription)")
            default:
                break
            }
        }
    }
}

// MARK: - Logging

extension MeshController: LoggerDelegate {
    /// Forwards NordicMesh's info-level-and-above logs to the VegaBar log.
    nonisolated func log(message: String, ofCategory category: LogCategory, withLevel level: LogLevel) {
        guard level.rawValue >= LogLevel.info.rawValue else { return }
        Log.info(.mesh, "[\(category)] \(message)")
    }
}

/// Keeps the mesh network (keys + nodes) in Application Support rather than the
/// library's default of ~/Documents, migrating an existing file once.
struct AppSupportStorage: Storage {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VegaBar", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("MeshNetwork.json")
    private var url: URL { Self.fileURL }

    init() {
        let fm = FileManager.default
        // The folder holds mesh keys: owner-only, and the files inside are 0600.
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.directory.path)
        if fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let legacy = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/MeshNetwork.json")
        if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: legacy.path) {
            do {
                try fm.moveItem(at: legacy, to: url)
                Log.info(.storage, "migrated mesh network from ~/Documents")
            } catch {
                Log.error(.storage, "mesh network migration failed: \(error.localizedDescription)")
            }
        }
    }

    func load() -> Data? { try? Data(contentsOf: url) }

    /// Writes atomically, preferring file protection; falls back to a plain
    /// atomic write where that protection class isn't supported.
    func save(_ data: Data) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            Log.error(.storage, "writing MeshNetwork.json failed: \(error.localizedDescription)")
            return false
        }
    }
}
