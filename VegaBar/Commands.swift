import Foundation

/// The one command layer behind Shortcuts, the CLI, URLs, hotkeys and the
/// menubar gestures, so they all behave identically.
@MainActor
extension AppModel {
    /// Turns the light on (if needed) and applies the preset's values.
    func applyPreset(_ preset: Preset) {
        if !isOn { setPower(true) }
        setBrightness(preset.brightness)
        setCCT(preset.colorTemperature)
    }

    /// Nudges brightness, turning the light on when brightening from off.
    func adjustBrightness(by delta: Double) {
        if !isOn && delta > 0 { setPower(true) }
        setBrightness(min(max((brightness + delta).rounded(), 0), 100))
    }

    /// Nudges colour temperature, snapped to 50 K steps.
    func adjustColorTemp(by delta: Double) {
        setCCT(((cct + delta) / 50).rounded() * 50)
    }

    /// A snapshot for replies and Shortcuts results.
    var status: ControlProtocol.Status {
        .init(light: selected?.name, connected: isConnected, on: isOn,
              brightness: Int(brightness.rounded()), colorTemperature: Int(cct.rounded()),
              battery: battery, presets: Preferences.shared.presets.map(\.name))
    }

    /// Executes a control request, waiting for the light link when needed.
    ///
    /// Commands that change the light are followed by a read-back, so the
    /// returned status is what the light reports, not merely what was asked.
    /// A request is refused (`ok == false`) when there is no registered light to
    /// address, so scripts never get a false "done".
    func perform(_ request: ControlProtocol.Request) async -> ControlProtocol.Response {
        typealias R = ControlProtocol.Response
        if request.command == .presets {
            return R(ok: true, status: status)
        }
        // Reject nonsense before it gets anywhere near the light. (Ranges are
        // also clamped by the encoder and re-validated by LightSafety.)
        if let v = request.value, !v.isFinite { return R(ok: false, error: "Value must be a number.") }

        guard let light = selected else { return R(ok: false, error: "No light is paired. Pair one from the VegaBar menu.") }
        guard await waitUntilConnected() else {
            let why = light.zyId == nil ? "\(light.name) hasn't finished registering yet." : "Couldn't connect to \(light.name)."
            return R(ok: false, error: why, status: status)
        }

        switch request.command {
        case .status:
            await refresh()
            return R(ok: true, status: status)
        case .on: setPower(true)
        case .off: setPower(false)
        case .toggle: setPower(!isOn)
        case .identify:
            identify()
            return R(ok: true, status: status)
        case .brightness:
            guard let v = request.value else { return R(ok: false, error: "Missing brightness value.") }
            if request.relative == true { adjustBrightness(by: v) } else {
                if !isOn, v > 0 { setPower(true) }
                setBrightness(v)
            }
        case .cct:
            guard let v = request.value else { return R(ok: false, error: "Missing color temperature.") }
            if request.relative == true { adjustColorTemp(by: v) } else { setCCT(v) }
        case .preset:
            guard let name = request.name, let preset = Preferences.shared.preset(named: name) else {
                return R(ok: false, error: "No preset named \"\(request.name ?? "")\". Presets: \(Preferences.shared.presets.map(\.name).joined(separator: ", "))")
            }
            applyPreset(preset)
        case .presets: break
        }
        // Let the throttled write go out, then read the real state back.
        try? await Task.sleep(for: .milliseconds(150))
        await refresh()
        return R(ok: true, status: status)
    }
}
