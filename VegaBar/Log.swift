import Foundation
import os

/// Logging for VegaBar, built on the unified logging system (`os.Logger`).
///
/// Messages appear in Console.app under the subsystem `org.dasmart.vegabar`
/// and are included in sysdiagnose reports. Unified logging takes care of
/// rotation and retention, so nothing here grows without bound.
///
/// Every message is marked `.public`: this is a single-user utility whose
/// logs describe a lamp, and redaction would only hide the facts you need when
/// something goes wrong. Nothing secret is ever logged (mesh keys are never
/// formatted into messages; the nRF library's own logger is routed here at
/// `.info` and above only).
///
/// Separately, `Log.trace` records raw Bluetooth frames and advertisements.
/// That stream is noisy, so it goes to Console at `.debug` (not persisted) and,
/// only when the user turns on "Log Bluetooth frames to a file", to a bounded
/// file for protocol debugging. See `FrameTrace`.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "org.dasmart.vegabar"

    enum Category: String {
        case app, ble, mesh, pairing, control, automation, safety, hotkeys, storage
    }

    private static let loggers: [Category: Logger] = Dictionary(uniqueKeysWithValues:
        [Category.app, .ble, .mesh, .pairing, .control, .automation, .safety, .hotkeys, .storage]
            .map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })

    private static func logger(_ c: Category) -> Logger { loggers[c]! }

    /// Routine events worth keeping: connections, pairing steps, decisions.
    /// Logged at `.notice` (the default level) because `.info` is held only in
    /// memory and wouldn't be there when someone looks in Console afterwards.
    static func info(_ category: Category, _ message: String) {
        logger(category).notice("\(message, privacy: .public)")
        FrameTrace.write("[\(category.rawValue)] \(message)")
    }

    /// Something went wrong that the user may notice or that explains a failure.
    static func error(_ category: Category, _ message: String) {
        logger(category).error("\(message, privacy: .public)")
        FrameTrace.write("[\(category.rawValue)] ERROR \(message)")
    }

    /// High-volume protocol detail (every frame, every advertisement). Shown in
    /// Console only while streaming at debug level; written to the trace file
    /// only when the user has enabled it.
    static func trace(_ message: @autoclosure () -> String) {
        let text = message()
        logger(.ble).debug("\(text, privacy: .public)")
        FrameTrace.write(text)
    }
}

/// Optional, bounded, on-disk copy of the frame trace, for protocol debugging.
/// Off by default. The file is capped at `maxBytes`; when exceeded it is rotated
/// to `VegaBar.log.old` (one generation), so at most ~2 × `maxBytes` is kept.
enum FrameTrace {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VegaBar.log")
    private static let oldURL = url.appendingPathExtension("old")
    static let maxBytes = 2 * 1024 * 1024

    /// Mirrors Preferences.frameTraceEnabled; read directly from defaults so this
    /// can be called from any thread without touching the main-actor Preferences.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "frameTraceEnabled") }

    private static let lock = OSAllocatedUnfairLock()
    // Thread-safe per Foundation docs, and only used under `lock`.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String) {
        guard isEnabled, let data = "\(formatter.string(from: Date())) \(message)\n".data(using: .utf8) else { return }
        lock.withLock {
            rotateIfNeeded()
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: url, to: oldURL)
    }
}
