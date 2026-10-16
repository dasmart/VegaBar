import Foundation
import Observation

/// A saved brightness + colour temperature, applied from the menu, Settings,
/// the camera automation, Shortcuts or the CLI (`vegabar preset <name>`).
struct Preset: Codable, Identifiable, Hashable {
    /// Stable identity, so renaming a preset doesn't break the camera setting or
    /// existing shortcuts.
    var id = UUID()
    /// Matched case-insensitively by name from the CLI, URLs and Shortcuts.
    var name: String
    /// Percent.
    var brightness: Double
    /// Kelvin.
    var colorTemperature: Double
}

/// A user-assigned global shortcut: Carbon key code + Carbon modifier mask.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …), not AppKit flags.
    var modifiers: UInt32
    /// The label shown in Settings, e.g. "⌃⌥↑", captured when recorded.
    var display: String
}

/// The actions a global shortcut can trigger. Each action's index in
/// `allCases` is used as its Carbon hot-key id (see `Hotkeys`); assignments
/// are stored by raw value, so reordering cases is safe.
enum HotkeyAction: String, Codable, CaseIterable, Identifiable {
    case togglePower, brightnessUp, brightnessDown, warmer, cooler
    var id: String { rawValue }
    var title: String {
        switch self {
        case .togglePower: "Toggle power"
        case .brightnessUp: "Brightness up"
        case .brightnessDown: "Brightness down"
        case .warmer: "Warmer"
        case .cooler: "Cooler"
        }
    }
}

/// User settings, persisted in UserDefaults.
///
/// Each property writes itself back on change, and defaults are applied in
/// `init` only when a key has never been stored, so turning a toggle off is
/// remembered. `@Observable` lets SwiftUI and `Automations` read it directly.
@MainActor
@Observable
final class Preferences {
    /// Shared instance used by the UI, hotkeys and automations.
    static let shared = Preferences()
    private let defaults: UserDefaults

    /// Stored as JSON, in the user's order. The first four appear in the menu.
    /// Names are capped at `maxPresetNameLength` characters on the way in.
    var presets: [Preset] {
        didSet {
            let capped = presets.map { p in
                var p = p
                if p.name.count > Self.maxPresetNameLength { p.name = String(p.name.prefix(Self.maxPresetNameLength)) }
                return p
            }
            if capped != presets { presets = capped; return }
            save(presets, "presets")
        }
    }
    static let maxPresetNameLength = 40

    // Camera
    /// Turn the light on when any camera starts streaming.
    var cameraAutoOn: Bool { didSet { defaults.set(cameraAutoOn, forKey: "cameraAutoOn") } }
    /// Preset applied when the camera starts (nil = just turn on).
    var cameraPresetId: UUID? { didSet { defaults.set(cameraPresetId?.uuidString, forKey: "cameraPresetId") } }
    /// Turn the light off when the camera stops, but only if VegaBar turned it on.
    var cameraAutoOff: Bool { didSet { defaults.set(cameraAutoOff, forKey: "cameraAutoOff") } }

    // Follow the Mac
    var offWhenMacSleeps: Bool { didSet { defaults.set(offWhenMacSleeps, forKey: "offWhenMacSleeps") } }
    var offWhenScreenLocks: Bool { didSet { defaults.set(offWhenScreenLocks, forKey: "offWhenScreenLocks") } }

    // Time-of-day colour temperature
    /// Blend colour temperature between the day and evening values.
    var autoColorTemp: Bool { didSet { defaults.set(autoColorTemp, forKey: "autoColorTemp") } }
    var dayKelvin: Double { didSet { defaults.set(dayKelvin, forKey: "dayKelvin") } }
    var eveningKelvin: Double { didSet { defaults.set(eveningKelvin, forKey: "eveningKelvin") } }
    /// Minutes after midnight.
    var eveningStart: Int { didSet { defaults.set(eveningStart, forKey: "eveningStart") } }
    var morningStart: Int { didSet { defaults.set(morningStart, forKey: "morningStart") } }

    // Hotkeys
    /// Stored as JSON.
    var hotkeys: [HotkeyAction: KeyCombo] { didSet { save(hotkeys, "hotkeys") } }
    /// Percentage points per brightness-up / down hotkey press.
    var brightnessStep: Double { didSet { defaults.set(brightnessStep, forKey: "brightnessStep") } }
    /// Kelvin per warmer / cooler hotkey press.
    var kelvinStep: Double { didSet { defaults.set(kelvinStep, forKey: "kelvinStep") } }

    /// Write every Bluetooth frame to ~/Library/Logs/VegaBar.log (see `FrameTrace`).
    /// Off by default; it's a protocol-debugging aid, not an activity log.
    var frameTraceEnabled: Bool { didSet { defaults.set(frameTraceEnabled, forKey: "frameTraceEnabled") } }

    /// - parameter defaults: the backing store; tests pass a throwaway suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        /// Decodes a JSON-encoded value stored under `key`.
        func load<T: Decodable>(_ key: String) -> T? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        presets = load("presets") ?? [
            Preset(name: "Call", brightness: 40, colorTemperature: 4300),
            Preset(name: "Bright", brightness: 100, colorTemperature: 5600),
            Preset(name: "Evening", brightness: 25, colorTemperature: 3000),
        ]
        // `object(forKey:) as? Bool ?? default` rather than `bool(forKey:)`, so a
        // stored false is distinguished from "never set".
        cameraAutoOn = defaults.object(forKey: "cameraAutoOn") as? Bool ?? false
        cameraPresetId = defaults.string(forKey: "cameraPresetId").flatMap(UUID.init(uuidString:))
        cameraAutoOff = defaults.object(forKey: "cameraAutoOff") as? Bool ?? true
        offWhenMacSleeps = defaults.object(forKey: "offWhenMacSleeps") as? Bool ?? false
        offWhenScreenLocks = defaults.object(forKey: "offWhenScreenLocks") as? Bool ?? false
        autoColorTemp = defaults.object(forKey: "autoColorTemp") as? Bool ?? false
        dayKelvin = defaults.object(forKey: "dayKelvin") as? Double ?? 5600
        eveningKelvin = defaults.object(forKey: "eveningKelvin") as? Double ?? 3200
        eveningStart = defaults.object(forKey: "eveningStart") as? Int ?? 19 * 60
        morningStart = defaults.object(forKey: "morningStart") as? Int ?? 7 * 60
        hotkeys = load("hotkeys") ?? [:]
        brightnessStep = defaults.object(forKey: "brightnessStep") as? Double ?? 10
        kelvinStep = defaults.object(forKey: "kelvinStep") as? Double ?? 300
        frameTraceEnabled = defaults.bool(forKey: "frameTraceEnabled")
    }

    /// Case-insensitive lookup, used by the CLI, URLs and Shortcuts.
    func preset(named name: String) -> Preset? {
        presets.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// JSON-encodes a Codable setting into UserDefaults.
    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
