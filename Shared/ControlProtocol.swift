import Foundation

/// Messages exchanged between the `vegabar` CLI and the running app over a
/// Unix domain socket: one JSON object per line in each direction.
///
/// This file is compiled into both targets (the app and `vegabar-cli`), so the
/// two always agree on the format. All fields are plain JSON types, which also
/// makes the socket usable from scripts, e.g. with `nc -U`.
enum ControlProtocol {
    /// Must match PRODUCT_BUNDLE_IDENTIFIER in project.yml. Used by the CLI only
    /// as a fallback for launching the app when it can't locate the bundle it
    /// is embedded in.
    static let appBundleIdentifier = "org.dasmart.vegabar"

    /// Path of the socket. It lives in the user's own Application Support folder
    /// and the app sets mode 0600 on it, so only this user can connect. The full
    /// path must fit in `sockaddr_un.sun_path` (104 bytes), which it does for any
    /// normal home folder.
    static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VegaBar/control.sock")
    }

    /// One command for the app, as sent by the CLI, a `vegabar://` URL or a
    /// Shortcuts action (all of which build a `Request` and call `AppModel.perform`).
    struct Request: Codable {
        /// `status` and `presets` only read; `presets` doesn't even need the light.
        enum Command: String, Codable {
            case status, on, off, toggle, brightness, cct, preset, presets, identify
        }
        var command: Command
        /// Numeric argument (brightness %, Kelvin, or a relative step when `relative`).
        var value: Double?
        /// True when `value` is a step to add (from a leading + or -), not a target.
        var relative: Bool?
        /// Preset name.
        var name: String?
    }

    /// Snapshot of the selected light as the app last knew it. Values come from
    /// the light's own read replies wherever possible (see `AppModel.received`).
    struct Status: Codable {
        /// Name of the selected light, if one is paired.
        var light: String?
        var connected: Bool
        var on: Bool
        /// Percent, rounded.
        var brightness: Int
        /// Kelvin, rounded.
        var colorTemperature: Int
        /// Percent; nil if the light hasn't reported it.
        var battery: Int?
        /// Names of the saved presets, in the user's order.
        var presets: [String]
    }

    /// The answer to every request. On failure `error` is human-readable and
    /// `status` may still be included.
    struct Response: Codable {
        var ok: Bool
        var error: String?
        var status: Status?
    }
}
