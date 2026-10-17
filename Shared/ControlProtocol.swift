import Foundation
import Security

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

    /// Path of the socket. The app sets mode 0600 on it, so only this user can
    /// connect. The full path must fit in `sockaddr_un.sun_path` (104 bytes),
    /// which it does for any normal home folder.
    ///
    /// - Direct download and Homebrew builds aren't sandboxed: the socket lives
    ///   in the user's Application Support folder.
    /// - The Mac App Store build is sandboxed, so the app and the CLI each get
    ///   their own container and can't see each other's files. The socket goes
    ///   in the App Group container they share instead.
    ///
    /// A sandboxed build with no team (`./build-appstore.sh --local`) has no
    /// group; it uses the top of its own container, since the container's
    /// Application Support path is too long for a socket.
    static var socketURL: URL {
        let fm = FileManager.default
        if let group = appGroupIdentifier,
           let container = fm.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return container.appendingPathComponent("control.sock")
        }
        if isSandboxed {
            // In the sandbox the home folder *is* the container.
            return fm.homeDirectoryForCurrentUser.appendingPathComponent("control.sock")
        }
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VegaBar/control.sock")
    }

    /// True in the Mac App Store build: the sandbox sets this for every process it contains.
    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// The App Group the sandboxed app and CLI share: `<TEAMID>.org.dasmart.vegabar`,
    /// matching both entitlements files. Nil when not sandboxed, or when the
    /// code has no team (an ad-hoc local build), where there is no group to use.
    static let appGroupIdentifier: String? = {
        guard isSandboxed, let team = signingTeamIdentifier() else { return nil }
        return "\(team).\(appBundleIdentifier)"
    }()

    /// The team identifier this process is signed with, read from its own code
    /// signature, so the App Group needn't be hard-coded per team.
    private static func signingTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
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
