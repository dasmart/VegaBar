import Foundation

/// Parses vegabar:// URLs (handy from Shortcuts' "Open URL", Raycast, etc.).
///
/// The host is the command and the first path component its argument:
/// `vegabar://on`, `vegabar://brightness/40`, `vegabar://cct/+300`,
/// `vegabar://preset/Call`. URLs are untrusted input, but they only map onto
/// the same `ControlProtocol.Request` the CLI sends, and every resulting frame
/// is still checked by `LightSafety`.
enum URLCommand {
    /// Returns nil for anything that isn't a recognised `vegabar://` command.
    static func request(from url: URL) -> ControlProtocol.Request? {
        guard url.scheme == "vegabar", let host = url.host()?.lowercased() else { return nil }
        // Percent-decoded so preset names with spaces work ("preset/Late%20call").
        let arg = url.pathComponents.dropFirst().first?.removingPercentEncoding
        // A leading + or - makes the number a relative step rather than a target.
        func number() -> (Double, Bool)? {
            guard let arg, let v = Double(arg) else { return nil }
            return (v, arg.hasPrefix("+") || arg.hasPrefix("-"))
        }
        switch host {
        case "on": return .init(command: .on)
        case "off": return .init(command: .off)
        case "toggle": return .init(command: .toggle)
        case "identify": return .init(command: .identify)
        case "brightness": return number().map { .init(command: .brightness, value: $0.0, relative: $0.1) }
        case "cct", "temperature": return number().map { .init(command: .cct, value: $0.0, relative: $0.1) }
        case "preset": return arg.map { .init(command: .preset, name: $0) }
        default: return nil
        }
    }
}
