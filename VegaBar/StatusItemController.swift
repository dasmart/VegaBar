import AppKit
import SwiftUI

/// The menubar icon. Click opens the controls; ⌥-click or right-click toggles
/// power; scrolling over the icon dims or brightens the light.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    /// Square status item: just the bulb icon.
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel
    /// Local monitor that catches scroll-wheel events over the status item.
    private var scrollMonitor: Any?
    /// Fractional scroll that hasn't added up to a whole percent yet.
    private var scrollAccumulator: CGFloat = 0
    /// Closes the popover on any click outside it. A status-item popover in an
    /// accessory app doesn't reliably get "resign" events, so `.transient` alone
    /// leaves it floating over other windows.
    private var outsideClickMonitor: Any?

    /// Builds the popover and icon, and starts tracking model changes for the icon.
    init(model: AppModel) {
        self.model = model
        super.init()
        // Transient: closes when the user clicks anywhere else.
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuView(model: model))

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            // Right-click doesn't trigger a button action by default; ask for both.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "VegaBar — click for controls, ⌥-click to toggle, scroll to dim"
        }
        // A local monitor sees scrolls in our own windows only, which includes the
        // status item's window. Only those are consumed; any other scroll passes on.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window == self.item.button?.window else { return event }
            self.scrolled(event)
            return nil
        }
        // Keep the icon in sync with connection and power state.
        observeChanges { [weak self] in self?.updateIcon() }
        // Anything that opens one of our own windows (Settings) closes the menu.
        NotificationCenter.default.addObserver(forName: .vegaBarWillShowWindow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    // MARK: NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    /// Bulb with a slash when disconnected (and greyed out), filled when on,
    /// outline when off.
    private func updateIcon() {
        // Three states: filled = giving light, outline = connected but dark
        // (off, or on at 0 %), slashed = no connection.
        let connected = model.isConnected
        let lit = model.isOn && model.brightness > 0
        let name = !connected ? "lightbulb.slash" : lit ? "lightbulb.fill" : "lightbulb"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "VegaBar")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.appearsDisabled = !connected
    }

    /// Plain click toggles the popover; right-click or ⌥-click toggles power.
    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            if model.isConnected { model.setPower(!model.isOn) }
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Activating first means clicking any other app deactivates us, which
            // is what makes a transient popover close.
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // Make the popover key so its controls take keyboard input at once.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Turns scrolling over the icon into brightness steps of whole percent.
    private func scrolled(_ event: NSEvent) {
        guard model.isConnected else { return }
        // Normalise so positive = fingers / wheel physically moving up = brighter,
        // regardless of the "natural scrolling" setting.
        var delta = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { delta = -delta }
        // Trackpads send many small precise deltas; mice send whole notches.
        scrollAccumulator += event.hasPreciseScrollingDeltas ? delta / 6 : delta * 2
        // Act on whole steps only and keep the remainder, so slow trackpad
        // scrolls still add up.
        let step = scrollAccumulator.rounded(.towardZero)
        guard step != 0 else { return }
        scrollAccumulator -= step
        model.adjustBrightness(by: Double(step))
    }
}

/// Hosts the SwiftUI settings in a normal window (menubar apps have no menu bar
/// to reach SwiftUI's Settings scene from).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static var tabs: NSTabViewController?

    static func show(tab: SettingsView.Tab = .general) {
        if window == nil {
            // Toolbar-style tabs (icon over label in the title bar) are the
            // standard look for a macOS Settings window.
            let controller = NSTabViewController()
            controller.tabStyle = .toolbar
            controller.canPropagateSelectedChildViewControllerTitle = true
            for pane in SettingsView.Tab.allCases {
                let host = NSHostingController(rootView: pane.makeView())
                host.title = pane.title
                host.preferredContentSize = pane.size
                let item = NSTabViewItem(viewController: host)
                item.label = pane.title
                item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
                controller.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.toolbarStyle = .preference
            // Keep the window object after close so the next `show` reuses it.
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            tabs = controller
        }
        tabs?.selectedTabViewItemIndex = tab.rawValue
        // An accessory app isn't active by default; activate so the window comes
        // to the front.
        NotificationCenter.default.post(name: .vegaBarWillShowWindow, object: nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    /// Posted just before VegaBar brings up one of its own windows.
    static let vegaBarWillShowWindow = Notification.Name("org.dasmart.vegabar.willShowWindow")
}