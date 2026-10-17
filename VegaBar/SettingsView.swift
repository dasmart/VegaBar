import AppKit
import SwiftUI

/// The settings window: General, Automation, Hotkeys and Presets tabs.
/// The Settings panes. The window itself is AppKit (see `SettingsWindow`): an
/// `NSTabViewController` with toolbar-style tabs, which is how macOS Settings
/// windows look, hosting one SwiftUI view per pane.
enum SettingsView {
    enum Tab: Int, CaseIterable {
        case general, automation, hotkeys, presets

        var title: String {
            switch self {
            case .general: "General"
            case .automation: "Automation"
            case .hotkeys: "Hotkeys"
            case .presets: "Presets"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .automation: "wand.and.stars"
            case .hotkeys: "keyboard"
            case .presets: "slider.horizontal.3"
            }
        }

        /// Each pane sizes its window; the tab controller animates between them.
        var size: NSSize {
            switch self {
            case .general: NSSize(width: 560, height: 520)
            case .automation: NSSize(width: 560, height: 560)
            case .hotkeys: NSSize(width: 560, height: 400)
            case .presets: NSSize(width: 560, height: 600)
            }
        }

        @MainActor
        func makeView() -> AnyView {
            switch self {
            case .general: AnyView(GeneralSettings())
            case .automation: AnyView(AutomationSettings())
            case .hotkeys: AnyView(HotkeySettings())
            case .presets: AnyView(PresetSettings())
            }
        }
    }
}

// MARK: - General

/// Login item, light names, CLI installation and the log.
struct GeneralSettings: View {
    @Bindable var model = AppModel.shared
    @Bindable var prefs = Preferences.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var cliMessage: String?
    @State private var cliInstalling = false
    /// Unsaved name edits, keyed by light, until Rename or Return commits them.
    @State private var names: [UUID: String] = [:]

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch VegaBar at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        loginError = LoginItem.set(on)
                        // Re-read the real state: registration can fail or need approval.
                        launchAtLogin = LoginItem.isEnabled
                        if LoginItem.needsApproval {
                            loginError = "Approve VegaBar in System Settings › General › Login Items."
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Lights") {
                if model.lights.isEmpty { Text("No lights paired.").foregroundStyle(.secondary) }
                ForEach(model.lights) { light in
                    HStack {
                        NameField(placeholder: "Light name",
                                  text: Binding(get: { names[light.id] ?? light.name }, set: { names[light.id] = $0 }),
                                  onCommit: { commitName(light) })
                        Button("Rename") { commitName(light) }
                            .disabled((names[light.id] ?? light.name) == light.name)
                        Button("Identify") { model.select(light); model.identify() }
                    }
                }
                Text("Names are stored in VegaBar; the light keeps broadcasting its own name.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Command line") {
                HStack {
                    Text("vegabar").font(.body.monospaced())
                    Spacer()
                    if cliInstalling { ProgressView().controlSize(.small) }
                    Button("Install Command-Line Tool") {
                        cliInstalling = true
                        Task {
                            cliMessage = await CLIInstaller.install()
                            cliInstalling = false
                        }
                    }
                    .disabled(cliInstalling)
                }
                Text(cliMessage ?? "Try: vegabar status · vegabar brightness 40 · vegabar cct 5600 · vegabar preset Call")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("URLs work too, e.g. vegabar://brightness/+10 from Shortcuts' Open URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Toggle("Log Bluetooth frames to a file", isOn: $prefs.frameTraceEnabled)
                Text(prefs.frameTraceEnabled
                     ? "Every frame sent and received goes to ~/Library/Logs/VegaBar.log (capped at 2 MB, one older copy kept). Turn this off when you're done debugging."
                     : "Events are in Console.app under the subsystem \(Log.subsystem). Turn this on only to capture raw frames.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Console") { LogViewer.openConsole() }
                    if prefs.frameTraceEnabled {
                        Button("Show Frame Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([FrameTrace.url]) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Saves an edited name (trimmed; empty names are ignored).
    private func commitName(_ light: Light) {
        let name = (names[light.id] ?? light.name).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.rename(light, to: name)
        names[light.id] = nil
    }
}

// MARK: - Automation

/// Camera, sleep / lock and time-of-day colour temperature options.
struct AutomationSettings: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Camera") {
                Toggle("Turn the light on when a camera is in use", isOn: $prefs.cameraAutoOn)
                Picker("When the camera starts", selection: $prefs.cameraPresetId) {
                    Text("Just turn on").tag(UUID?.none)
                    ForEach(prefs.presets) { Text("Apply “\($0.name)”").tag(UUID?.some($0.id)) }
                }
                .disabled(!prefs.cameraAutoOn)
                Toggle("Turn it off again when the camera stops", isOn: $prefs.cameraAutoOff)
                    .disabled(!prefs.cameraAutoOn)
                Text("Works with any app — FaceTime, Zoom, Meet, Photo Booth. Only turns off a light it turned on.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Follow the Mac") {
                Toggle("Turn off when the Mac sleeps", isOn: $prefs.offWhenMacSleeps)
                Toggle("Turn off when the screen locks", isOn: $prefs.offWhenScreenLocks)
                Text("The light comes back on when you return, if VegaBar turned it off.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Time-of-day color temperature") {
                Toggle("Adjust color temperature through the day", isOn: $prefs.autoColorTemp)
                    // Turning the feature on applies the schedule immediately.
                    .onChange(of: prefs.autoColorTemp) { _, on in if on { Automations.shared.resumeColorSchedule() } }
                Group {
                    LabeledContent("Daytime") {
                        Stepper("\(Int(prefs.dayKelvin))K", value: $prefs.dayKelvin, in: 2700...6500, step: 100)
                    }
                    LabeledContent("Evening") {
                        Stepper("\(Int(prefs.eveningKelvin))K", value: $prefs.eveningKelvin, in: 2700...6500, step: 100)
                    }
                    DatePicker("Evening starts", selection: minutesBinding(\.eveningStart), displayedComponents: .hourAndMinute)
                    DatePicker("Morning starts", selection: minutesBinding(\.morningStart), displayedComponents: .hourAndMinute)
                }
                .disabled(!prefs.autoColorTemp)
                Text("Blends over an hour around each start time. Moving the color slider yourself pauses it until the next change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Bridges a "minutes after midnight" preference to the Date a DatePicker
    /// needs (today's date at that time) and back.
    private func minutesBinding(_ key: ReferenceWritableKeyPath<Preferences, Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: prefs[keyPath: key] / 60, minute: prefs[keyPath: key] % 60,
                                         second: 0, of: Date()) ?? Date() },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                prefs[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

// MARK: - Hotkeys

/// Recorders for each global shortcut, plus how far each press moves.
struct HotkeySettings: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.title) { HotkeyRecorder(action: action) }
                }
            } footer: {
                Text("Shortcuts work in any app. Use ⌘, ⌥ or ⌃ in each one. Esc cancels recording; Delete clears.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Step sizes") {
                LabeledContent("Brightness") {
                    Stepper("\(Int(prefs.brightnessStep))%", value: $prefs.brightnessStep, in: 1...50)
                }
                LabeledContent("Color temperature") {
                    Stepper("\(Int(prefs.kelvinStep))K", value: $prefs.kelvinStep, in: 50...1000, step: 50)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Presets

/// Edit, reorder, apply and delete presets, or add one from the light's
/// current settings.
struct PresetSettings: View {
    @Bindable var prefs = Preferences.shared
    @Bindable var model = AppModel.shared
    /// Names being edited, keyed by preset id. Typing goes here rather than
    /// straight into `prefs.presets`, so each keystroke doesn't rewrite and
    /// re-render the whole list; the name is saved on Return or when the field
    /// loses focus.
    @State private var drafts: [UUID: String] = [:]

    var body: some View {
        Form {
            ForEach($prefs.presets) { $preset in
                Section { presetEditor($preset) }
            }
            Section {
                HStack {
                    Button("Add From Current Light") {
                        prefs.presets.append(Preset(name: "Preset \(prefs.presets.count + 1)",
                                                    brightness: model.brightness, colorTemperature: model.cct))
                    }
                    Spacer()
                    Text("Presets also appear in Shortcuts and the CLI.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Saves an edited name; blank names keep the old one.
    private func commitName(_ id: UUID) {
        guard let draft = drafts.removeValue(forKey: id) else { return }
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = prefs.presets.firstIndex(where: { $0.id == id }) else { return }
        if prefs.presets[i].name != name { prefs.presets[i].name = name }
    }

    /// Snaps a slider's value to multiples of `step` without using Slider's own
    /// `step:`, which on macOS renders a tick mark for every step.
    private func rounded(_ value: Binding<Double>, to step: Double) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / step).rounded() * step })
    }

    /// One preset: name and actions on the first row, then a labelled slider
    /// per value with its reading on the right.
    private func presetEditor(_ preset: Binding<Preset>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                let id = preset.wrappedValue.id
                NameField(placeholder: "Preset name",
                          text: Binding(get: { drafts[id] ?? preset.wrappedValue.name }, set: { drafts[id] = $0 }),
                          onCommit: { commitName(id) })
                    .frame(maxWidth: 220)
                Spacer()
                Button("Apply") { model.applyPreset(preset.wrappedValue) }
                    .disabled(!model.isConnected)
                Button(role: .destructive) { prefs.presets.removeAll { $0.id == preset.wrappedValue.id } } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete preset")
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Label("Brightness", systemImage: "sun.max")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    // No `step:` — on macOS that draws a tick per step under the track.
                    Slider(value: rounded(preset.brightness, to: 1), in: 0...100)
                    Text(verbatim: "\(Int(preset.wrappedValue.brightness))%")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                GridRow {
                    Label("Color temperature", systemImage: "thermometer.medium")
                        .foregroundStyle(.secondary)
                    Slider(value: rounded(preset.colorTemperature, to: 50), in: 2700...6500)
                    Text(verbatim: "\(Int(preset.wrappedValue.colorTemperature))K")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }
}


/// Opens Console.app, where VegaBar's events are logged (subsystem
/// `org.dasmart.vegabar`). Console has no URL to pre-filter a subsystem, so the
/// General tab shows the name to search for.
enum LogViewer {
    static func openConsole() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
    }
}

/// A single-line text field with left-aligned text whether idle or editing.
///
/// SwiftUI's `TextField` inside a grouped `Form` on macOS right-aligns its idle
/// text (the "value column" look of System Settings) and only honours
/// `multilineTextAlignment` while editing, which looks like the text jumping.
/// Wrapping `NSTextField` directly gives one consistent alignment, and the
/// standard Edit-menu behaviour (select all, undo, paste) for free.
struct NameField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    /// Called on Return and when the field loses focus.
    var onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.alignment = .left
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Don't fight the user: only push model text in while they aren't typing.
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NameField
        init(_ parent: NameField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ note: Notification) {
            parent.onCommit()
        }
    }
}
