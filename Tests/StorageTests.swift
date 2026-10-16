import XCTest
@testable import VegaBar

final class StorageTests: XCTestCase {
    private var tempDir: URL!
    private var suiteNames: [String] = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vegabar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    }

    private func suite(_ tag: String) -> (String, UserDefaults) {
        let name = "org.dasmart.vegabar.tests.\(tag).\(UUID().uuidString)"
        suiteNames.append(name)
        return (name, UserDefaults(suiteName: name)!)
    }

    func testLightStorePersistsAndIsOwnerOnly() throws {
        let node = UUID()
        var store = LightStore(directory: tempDir, defaults: suite("ls").1)
        store.setZyId(0x8001, for: node)
        XCTAssertEqual(LightStore(directory: tempDir, defaults: suite("ls2").1).zyId(for: node), 0x8001)
        let perms = try FileManager.default.attributesOfItem(atPath: tempDir.appendingPathComponent("lights.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        store.remove(node)
        XCTAssertNil(LightStore(directory: tempDir, defaults: suite("ls3").1).zyId(for: node))
    }

    func testLightStoreImportsLegacyDeviceIdsOnce() {
        let (_, defaults) = suite("legacy")
        let node = UUID()
        defaults.set([node.uuidString: 0x8000], forKey: "deviceIds")
        let store = LightStore(directory: tempDir, defaults: defaults)
        XCTAssertEqual(store.zyId(for: node), 0x8000)
        XCTAssertNil(defaults.object(forKey: "deviceIds"), "legacy key is removed after import")
    }

    func testSettingsMigrationCopiesKnownKeysOnlyOnce() {
        let (oldName, old) = suite("old")
        let (_, new) = suite("new")
        old.set(42.0, forKey: "brightnessStep")
        old.set(true, forKey: "cameraAutoOn")
        old.set("evil", forKey: "notAVegaBarKey")
        new.set(5.0, forKey: "kelvinStep")   // pre-existing value must win
        old.set(999.0, forKey: "kelvinStep")

        XCTAssertEqual(SettingsMigration.run(from: [oldName], into: new), 2)
        XCTAssertEqual(new.double(forKey: "brightnessStep"), 42)
        XCTAssertTrue(new.bool(forKey: "cameraAutoOn"))
        XCTAssertEqual(new.double(forKey: "kelvinStep"), 5)
        XCTAssertNil(new.object(forKey: "notAVegaBarKey"))
        XCTAssertEqual(SettingsMigration.run(from: [oldName], into: new), 0, "runs once per domain")
    }

    @MainActor
    func testPresetNamesAreCapped() {
        let prefs = Preferences(defaults: suite("prefs").1)
        prefs.presets = [Preset(name: String(repeating: "x", count: 200), brightness: 10, colorTemperature: 3000)]
        XCTAssertEqual(prefs.presets.first?.name.count, Preferences.maxPresetNameLength)
    }
}
