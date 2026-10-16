import Foundation

/// One-time copy of settings from an earlier bundle identifier.
///
/// UserDefaults are stored per bundle id, so when VegaBar's id changed from
/// `org.smartfamilyfund.vegabar` to `org.dasmart.vegabar` every preference —
/// presets, hotkeys, automation switches, the selected light — would otherwise
/// have reset to defaults on the next launch. This runs before anything reads
/// defaults, copies each known key that the new domain doesn't already have,
/// and records that it ran. The old domain is left untouched.
enum SettingsMigration {
    static let legacyDomains = ["org.smartfamilyfund.vegabar"]
    private static let marker = "settingsMigratedFrom"

    /// Keys VegaBar has ever stored in UserDefaults. Unknown keys are ignored so
    /// a stray or malicious plist can't inject arbitrary defaults.
    static let knownKeys = [
        "selected", "deviceIds", "lastPeripheral",
        "presets", "hotkeys",
        "cameraAutoOn", "cameraPresetId", "cameraAutoOff",
        "offWhenMacSleeps", "offWhenScreenLocks",
        "autoColorTemp", "dayKelvin", "eveningKelvin", "eveningStart", "morningStart",
        "brightnessStep", "kelvinStep", "frameTraceEnabled",
    ]

    @discardableResult
    static func run(from domains: [String] = legacyDomains, into defaults: UserDefaults = .standard) -> Int {
        var copied = 0
        for domain in domains where domain != Bundle.main.bundleIdentifier {
            let done = defaults.stringArray(forKey: marker) ?? []
            guard !done.contains(domain), let legacy = UserDefaults(suiteName: domain) else { continue }
            for key in knownKeys where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) {
                    defaults.set(value, forKey: key)
                    copied += 1
                }
            }
            defaults.set(done + [domain], forKey: marker)
            if copied > 0 { Log.info(.storage, "migrated \(copied) setting(s) from \(domain)") }
        }
        return copied
    }
}
