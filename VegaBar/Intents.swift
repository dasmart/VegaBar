import AppIntents
import Foundation

// Shortcuts / Siri / Spotlight actions. They run inside VegaBar and use the same
// command layer as the CLI.

/// An intent failure carrying the app's own message, which Shortcuts shows
/// to the user as is.
struct VegaBarError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// Runs a request through the shared command layer and returns the resulting
/// status, or throws so the shortcut stops with the app's error message.
@MainActor
private func run(_ request: ControlProtocol.Request) async throws -> ControlProtocol.Status {
    let response = await AppModel.shared.perform(request)
    guard response.ok, let status = response.status else { throw VegaBarError(message: response.error ?? "The light didn't respond.") }
    return status
}

/// The power choices offered in the Shortcuts editor.
enum PowerAction: String, AppEnum {
    case on, off, toggle
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Power"
    static let caseDisplayRepresentations: [PowerAction: DisplayRepresentation] = [
        .on: "On", .off: "Off", .toggle: "Toggle",
    ]
}

/// Turns the light on, off, or toggles it. Returns the resulting power state.
struct SetPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Light On or Off"
    static let description = IntentDescription("Turns the ZY light on, off, or toggles it.")
    @Parameter(title: "Power", default: .toggle) var power: PowerAction

    static var parameterSummary: some ParameterSummary { Summary("Turn light \(\.$power)") }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let command: ControlProtocol.Request.Command = switch power { case .on: .on; case .off: .off; case .toggle: .toggle }
        return .result(value: try await run(.init(command: command)).on)
    }
}

/// Sets an absolute brightness. Above 0 % this also turns the light on.
struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Light Brightness"
    static let description = IntentDescription("Sets the light's brightness in percent. Turns the light on if needed.")
    @Parameter(title: "Brightness", inclusiveRange: (0, 100)) var brightness: Int

    static var parameterSummary: some ParameterSummary { Summary("Set brightness to \(\.$brightness)%") }

    func perform() async throws -> some IntentResult {
        _ = try await run(.init(command: .brightness, value: Double(brightness)))
        return .result()
    }
}

/// Nudges brightness up or down. Returns the new brightness.
struct AdjustBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Adjust Light Brightness"
    static let description = IntentDescription("Raises or lowers brightness by a number of percentage points.")
    @Parameter(title: "Change", default: 10, inclusiveRange: (-100, 100)) var change: Int

    static var parameterSummary: some ParameterSummary { Summary("Change brightness by \(\.$change)") }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: try await run(.init(command: .brightness, value: Double(change), relative: true)).brightness)
    }
}

/// Sets an absolute colour temperature, within the PL103's range.
struct SetColorTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Light Color Temperature"
    static let description = IntentDescription("Sets the color temperature in Kelvin (2700–6500).")
    @Parameter(title: "Kelvin", default: 5600, inclusiveRange: (2700, 6500)) var kelvin: Int

    static var parameterSummary: some ParameterSummary { Summary("Set color temperature to \(\.$kelvin)K") }

    func perform() async throws -> some IntentResult {
        _ = try await run(.init(command: .cct, value: Double(kelvin)))
        return .result()
    }
}

/// A saved preset as Shortcuts sees it. Identified by its UUID, so a renamed
/// preset stays selected in existing shortcuts.
struct PresetEntity: AppEntity {
    let id: UUID
    let name: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Light Preset"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static let defaultQuery = PresetQuery()
}

/// Supplies presets to the Shortcuts editor and resolves saved selections.
struct PresetQuery: EntityQuery {
    @MainActor private func all() -> [PresetEntity] {
        Preferences.shared.presets.map { PresetEntity(id: $0.id, name: $0.name) }
    }
    /// Resolved at run time, so the entity carries the preset's current name.
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        await all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [PresetEntity] { await all() }
}

/// Applies a preset. The request names the preset because that's how the
/// control protocol addresses presets (the CLI uses names too).
struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Light Preset"
    static let description = IntentDescription("Turns the light on with a saved brightness and color temperature.")
    @Parameter(title: "Preset") var preset: PresetEntity

    static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$preset)") }

    func perform() async throws -> some IntentResult {
        _ = try await run(.init(command: .preset, name: preset.name))
        return .result()
    }
}

/// One-line status, returned as text and also spoken / shown as a dialog.
struct GetLightStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Light Status"
    static let description = IntentDescription("Returns whether the light is on, its brightness and color temperature.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let s = try await run(.init(command: .status))
        var text = "\(s.light ?? "Light") is \(s.on ? "on" : "off"), \(s.brightness)%, \(s.colorTemperature)K"
        if let b = s.battery { text += ", battery \(b)%" }
        return .result(value: text, dialog: "\(text)")
    }
}

/// Brightness in percent, freshly read from the light.
struct GetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Light Brightness"
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: try await run(.init(command: .status)).brightness)
    }
}

/// Colour temperature in Kelvin, freshly read from the light.
struct GetColorTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Light Color Temperature"
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: try await run(.init(command: .status)).colorTemperature)
    }
}

/// Whether the light is on, freshly read from the light.
struct IsLightOnIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Light On"
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: try await run(.init(command: .status)).on)
    }
}

/// Ready-made shortcuts and Siri phrases that appear without any setup.
struct VegaBarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetPowerIntent(), phrases: ["Toggle the light with \(.applicationName)",
                                                       "Turn the light \(\.$power) with \(.applicationName)"],
                    shortTitle: "Light Power", systemImageName: "lightbulb")
        AppShortcut(intent: ApplyPresetIntent(), phrases: ["Apply \(\.$preset) in \(.applicationName)"],
                    shortTitle: "Apply Preset", systemImageName: "slider.horizontal.3")
        AppShortcut(intent: GetLightStatusIntent(), phrases: ["Get light status from \(.applicationName)"],
                    shortTitle: "Light Status", systemImageName: "info.circle")
    }
}
