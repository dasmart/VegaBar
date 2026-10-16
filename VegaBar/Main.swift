import AppKit

/// Entry point. VegaBar is an AppKit app (not a SwiftUI `App`) because the
/// menubar item needs behaviours `MenuBarExtra` doesn't offer: scroll-to-dim,
/// ⌥-click and right-click. SwiftUI is used for the views inside it.
@main
enum Main {
    static func main() {
        // Before anything reads UserDefaults: carry settings over from the old
        // bundle identifier, once.
        SettingsMigration.run()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menubar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var controlServer: ControlServer?

    /// True when the app is the host for `xcodebuild test`: the unit tests must
    /// not start Bluetooth, take over the control socket from a running copy of
    /// VegaBar, or register global hotkeys.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        let model = AppModel.shared
        statusItem = StatusItemController(model: model)
        controlServer = ControlServer(model: model)
        controlServer?.start()
        Automations.shared.start()
        Hotkeys.shared.reload()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
    }

    /// vegabar://on | off | toggle | brightness/40 | brightness/+10 | cct/5600 | preset/Call
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let request = URLCommand.request(from: url) else {
                Log.info(.app, "ignored URL \(url.absoluteString)")
                continue
            }
            Task { _ = await AppModel.shared.perform(request) }
        }
    }
}

/// Re-runs `apply` whenever any `@Observable` state it read changes. Used by
/// the AppKit status item, which can't rely on SwiftUI's view updates.
@MainActor
func observeChanges(_ apply: @escaping @MainActor @Sendable () -> Void) {
    withObservationTracking { apply() } onChange: {
        Task { @MainActor in observeChanges(apply) }
    }
}
