import SwiftUI

/// The popover shown from the menubar icon.
///
/// Three layouts: pairing (while `model.isPairing`), an empty state when no
/// light is paired, and otherwise the controls for the selected light plus the
/// list of paired lights. All actions go through `AppModel`, so they get the
/// same coalescing, rate limiting and `LightSafety` checks as everything else.
struct MenuView: View {
    @Bindable var model: AppModel
    @Bindable var prefs = Preferences.shared
    /// The light whose name is being edited inline, if any.
    @State private var renaming: Light?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let notice = model.notice { noticeView(notice) }
            Divider()
            if model.isPairing {
                pairingSection
            } else if model.lights.isEmpty {
                emptyState
            } else {
                controls
                Divider()
                lightList
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Notice

    /// A dismissible warning for problems the user must act on (a pairing file
    /// that couldn't be read, a light that could only be forgotten, a failed save).
    private func noticeView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.notice = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Header

    /// Selected light's name, connection status and battery; the power switch;
    /// and the settings button.
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selected?.name ?? "VegaBar").font(.headline)
                HStack(spacing: 6) {
                    Text(statusText)
                    if let battery = model.battery, model.isConnected {
                        Label("\(battery)%", systemImage: batterySymbol(battery)).labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.lights.isEmpty && !model.isPairing {
                // A custom binding so flipping the switch calls `setPower` (which sends
                // the frame and reads back) rather than just setting `isOn`.
                Toggle("", isOn: Binding(get: { model.isOn }, set: { model.setPower($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!model.isConnected)
            }
            Button { SettingsWindow.show() } label: {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Preferences…")
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    /// One-line connection status under the light's name.
    private var statusText: String {
        switch model.linkState {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth access denied — allow VegaBar in System Settings › Privacy & Security › Bluetooth"
        case .idle: return "Not connected"
        case .scanning: return model.lights.isEmpty ? "No lights paired" : "Looking for lights…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        }
    }

    // MARK: Controls

    /// Brightness and colour temperature sliders plus preset buttons. Disabled
    /// while disconnected, since nothing could be sent.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow(icon: "sun.max", label: "Brightness", value: "\(Int(model.brightness))%") {
                // Whole percent: finer steps aren't visible and only add frames.
                Slider(value: Binding(get: { model.brightness }, set: { model.setBrightness($0.rounded()) }),
                       in: 0...100)
            }
            sliderRow(icon: "thermometer.medium", label: "Color temperature", value: "\(Int(model.cct))K") {
                // 50 K steps, the same rounding the hotkeys and schedule use.
                Slider(value: Binding(get: { model.cct }, set: { model.setCCT(($0 / 50).rounded() * 50) }),
                       in: model.cctRange)
                    .tint(LinearGradient(colors: [.orange, .white, .cyan], startPoint: .leading, endPoint: .trailing))
            }
            presetRow
        }
        .disabled(!model.isConnected)
    }

    /// Unpairing makes the light leave its network (it must be re-paired from
    /// scratch), so it always asks first.
    private func confirmUnpair(_ light: Light) {
        let alert = NSAlert()
        alert.messageText = "Unpair \(light.name)?"
        alert.informativeText = model.isConnected
            ? "The light will be told to leave VegaBar's network. To use it again you'll need to pair it again."
            : "VegaBar isn't connected to this light, so it can only forget it. The light will keep its pairing and must be factory-reset (from its own menu) before it can be paired again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Unpair")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            Task { @MainActor in
                if case .forgottenOnly(let reason) = await model.unpair(light) { model.notice = reason }
            }
        }
    }

    /// Up to four presets as one-tap buttons, plus "+" to save the current
    /// settings as a new preset and open it in Settings for naming.
    private var presetRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(prefs.presets) { preset in
                Button {
                    model.applyPreset(preset)
                } label: {
                    Text(preset.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: 120)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("\(Int(preset.brightness))% · \(Int(preset.colorTemperature))K")
            }
            Button {
                prefs.presets.append(Preset(name: "Preset \(prefs.presets.count + 1)",
                                            brightness: model.brightness, colorTemperature: model.cct))
                SettingsWindow.show(tab: .presets)
            } label: { Image(systemName: "plus") }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Save the current settings as a preset")
        }
    }

    /// SF Symbol for a battery level, rounded to the nearest quarter.
    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    /// Icon, label and current value above a slider.
    private func sliderRow<S: View>(icon: String, label: String, value: String,
                                    @ViewBuilder slider: () -> S) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(label, systemImage: icon).font(.subheadline)
                Spacer()
                Text(value).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            slider()
        }
    }

    // MARK: Light list

    /// Paired lights. Tapping a row selects it; the ⋯ menu identifies, renames
    /// or unpairs it.
    private var lightList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Lights").font(.caption).foregroundStyle(.secondary)
            ForEach(model.lights) { light in
                HStack {
                    Image(systemName: light.id == model.selected?.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(light.id == model.selected?.id ? Color.accentColor : .secondary)
                    if renaming == light {
                        TextField("Name", text: $newName, onCommit: {
                            model.rename(light, to: newName)
                            renaming = nil
                        })
                        .textFieldStyle(.roundedBorder)
                    } else {
                        Text(light.name)
                    }
                    Spacer()
                    Menu {
                        // Select first so the blink goes to this light.
                        Button("Identify (blink)") { model.select(light); model.identify() }
                        Button("Rename…") { newName = light.name; renaming = light }
                        Divider()
                        Button("Unpair…", role: .destructive) { confirmUnpair(light) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .contentShape(Rectangle())
                .onTapGesture { model.select(light) }
            }
        }
    }

    // MARK: Pairing

    /// Shown when nothing is paired yet.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No lights paired yet.")
            Text("Put a light in pairing mode (reset it from the light's menu or the phone app), then pair it here.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Pair a light…") { model.startPairing() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// The pairing flow: lights in pairing mode (strongest signal first) and,
    /// separately, mesh lights that belong to another network such as the phone's,
    /// which have to be reset before VegaBar can pair them.
    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pair a light").font(.subheadline.bold())
            if let status = model.pairingStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if model.linkState == .unauthorized {
                Text("VegaBar doesn't have Bluetooth access. Turn it on in System Settings › Privacy & Security › Bluetooth, then reopen VegaBar.")
                    .font(.caption).foregroundStyle(.red)
                // Deep link to the Bluetooth pane of Privacy & Security.
                Button("Open Bluetooth Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                }.controlSize(.small)
            } else if model.unprovisioned.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Scanning…").font(.caption) }
            }
            ForEach(model.unprovisioned.sorted { $0.rssi > $1.rssi }) { d in
                HStack {
                    Image(systemName: "lightbulb")
                    Text(d.name)
                    Spacer()
                    Text("\(d.rssi) dBm").font(.caption2).foregroundStyle(.secondary)
                    Button("Pair") { model.pair(d) }.controlSize(.small)
                }
            }
            if !model.foreignLights.isEmpty {
                Divider()
                Text("Already paired elsewhere").font(.caption.bold())
                Text("These lights belong to another network (probably your phone). Unpair them in the ZY Vega app or factory-reset them, and they'll appear above.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.foreignLights.sorted { $0.rssi > $1.rssi }) { d in
                    HStack {
                        Image(systemName: "lightbulb.slash").foregroundStyle(.secondary)
                        Text(d.name).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(d.rssi) dBm").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Done") { model.stopPairing() }
                Spacer()
                // Console shows every advertisement and pairing step: the first place
                // to look when a light doesn't appear or pairing fails.
                Button("Open Console") { LogViewer.openConsole() }.buttonStyle(.borderless).font(.caption)
            }
        }
    }

    // MARK: Footer

    /// Pairing entry point, About and Quit.
    private var footer: some View {
        HStack {
            if !model.isPairing && !model.lights.isEmpty {
                Button("Pair a light…") { model.startPairing() }
            }
            Spacer()
            Button("About") { AboutPanel.show() }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

/// Lays out its children left to right, wrapping onto new lines when the row is
/// full, so any number of preset buttons fits the popover's fixed width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: place(in: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, place(in: bounds.width, subviews: subviews).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func place(in width: CGFloat, subviews: Subviews) -> (points: [CGPoint], height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {   // wrap
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (points, y + rowHeight)
    }
}
