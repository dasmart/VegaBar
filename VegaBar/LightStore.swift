import Foundation

/// VegaBar's own record of each paired light, kept next to the mesh network
/// file in `~/Library/Application Support/VegaBar/lights.json`.
///
/// The nRF Mesh library owns `MeshNetwork.json` (keys, nodes, addresses) and
/// its format is fixed, so the ZY-specific facts — chiefly the device id the
/// light was registered with — live here. Keeping both files in one folder
/// means a backup or restore of that folder carries the whole pairing state,
/// which UserDefaults (tied to the bundle id and stored elsewhere) did not.
///
/// If the two ever disagree, `AppModel` recovers: a connected light reports its
/// own device id, and an unregistered one is registered afresh.
struct LightStore {
    struct Record: Codable, Equatable {
        /// ZY device id assigned at registration (0x8000 and up).
        var zyId: UInt16?
    }

    private let url: URL
    private(set) var records: [UUID: Record]

    /// - parameter directory: where `lights.json` lives; defaults to the shared
    ///   Application Support folder. Tests pass a temporary directory.
    init(directory: URL = AppSupportStorage.directory, defaults: UserDefaults = .standard) {
        url = directory.appendingPathComponent("lights.json")
        records = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([UUID: Record].self, from: $0) } ?? [:]
        migrateFromDefaults(defaults)
    }

    func zyId(for node: UUID) -> UInt16? { records[node]?.zyId }

    /// All device ids in use, for choosing a free one at registration.
    var usedDeviceIds: Set<UInt16> { Set(records.values.compactMap(\.zyId)) }

    mutating func setZyId(_ id: UInt16?, for node: UUID) {
        records[node, default: Record()].zyId = id
        save()
    }

    mutating func remove(_ node: UUID) {
        records[node] = nil
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.error(.storage, "couldn't save lights.json: \(error.localizedDescription)")
        }
    }

    /// Versions before 0.3 kept `{nodeUUID: zyId}` in UserDefaults under
    /// "deviceIds". Import it once, then remove it so there is one source.
    private mutating func migrateFromDefaults(_ defaults: UserDefaults) {
        guard let legacy = defaults.dictionary(forKey: "deviceIds") as? [String: Int], !legacy.isEmpty else { return }
        for (key, value) in legacy {
            guard let node = UUID(uuidString: key), records[node]?.zyId == nil, (0...0xFFFF).contains(value) else { continue }
            records[node, default: Record()].zyId = UInt16(value)
        }
        save()
        defaults.removeObject(forKey: "deviceIds")
        Log.info(.storage, "migrated \(legacy.count) device id(s) from UserDefaults to lights.json")
    }
}
