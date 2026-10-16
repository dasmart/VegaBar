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
        NSApp.mainMenu = Self.makeMainMenu()
        let model = AppModel.shared
        statusItem = StatusItemController(model: model)
        controlServer = ControlServer(model: model)
        controlServer?.start()
        Automations.shared.start()
        Hotkeys.shared.reload()
    }

    /// A menubar-only app has no visible menu bar, but text fields still route
    /// ⌘A/⌘C/⌘V/⌘X/⌘Z through the main menu's Edit items, so one must exist.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit VegaBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        return main
    }

    @objc private func showPreferences() { SettingsWindow.show() }

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
