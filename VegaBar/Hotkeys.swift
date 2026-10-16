import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-wide shortcuts via Carbon's RegisterEventHotKey, which (unlike event
/// taps) needs no Accessibility permission.
///
/// Carbon glue in brief: each shortcut is registered with
/// `RegisterEventHotKey` under an `EventHotKeyID` whose `signature` is
/// VegaBar's four-char code and whose `id` is the action's index in
/// `HotkeyAction.allCases`. One application-level event handler receives every
/// hot-key press, reads that id back out of the event, and dispatches.
@MainActor
@Observable
final class Hotkeys {
    /// Shared instance; the Carbon callback can't capture context, so it uses this.
    static let shared = Hotkeys(model: .shared, prefs: .shared)
    private let model: AppModel
    private let prefs: Preferences
    /// Actions whose shortcut couldn't be registered (usually taken by another
    /// app), with a short reason for the Settings UI.
    private(set) var unavailable: [HotkeyAction: String] = [:]

    init(model: AppModel, prefs: Preferences) {
        self.model = model
        self.prefs = prefs
    }
    /// Registered hot keys, kept so they can be unregistered on reload.
    private var refs: [EventHotKeyRef] = []
    /// The event handler is installed once and stays for the app's lifetime.
    private var handlerInstalled = false
    private static let signature = OSType(0x5647_4252) // 'VGBR'

    /// Re-registers every shortcut from `Preferences`. Called at launch and after
    /// any shortcut changes. A combo already taken by another app fails to
    /// register and is just logged.
    func reload() {
        unregisterAll()
        unavailable = [:]
        installHandler()
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let combo = prefs.hotkeys[action] else { continue }
            var ref: EventHotKeyRef?
            // The index doubles as the hot-key id, so `fire` can map it back.
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else {
                unavailable[action] = status == eventHotKeyExistsErr ? "already used by another app" : "couldn't be registered (error \(status))"
                Log.error(.hotkeys, "hotkey \(combo.display) for \(action.title) unavailable (\(status))")
            }
        }
    }

    /// While recording a new shortcut, existing ones must not fire.
    func suspend() { unregisterAll() }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    /// Installs the Carbon event handler for hot-key presses on the application
    /// event target.
    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The handler is a C function pointer, so it can't capture anything: it reads
        // the hot-key id from the event's direct-object parameter and hops to the
        // main actor to act on it.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let index = Int(hotKey.id)
            Task { @MainActor in Hotkeys.shared.fire(index) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Performs the action for a pressed hot key. Ignored while disconnected,
    /// since nothing could be sent anyway.
    private func fire(_ index: Int) {
        guard HotkeyAction.allCases.indices.contains(index) else { return }
        guard model.isConnected else { return }
        switch HotkeyAction.allCases[index] {
        case .togglePower: model.setPower(!model.isOn)
        case .brightnessUp: model.adjustBrightness(by: prefs.brightnessStep)
        case .brightnessDown: model.adjustBrightness(by: -prefs.brightnessStep)
        case .warmer: model.adjustColorTemp(by: -prefs.kelvinStep)
        case .cooler: model.adjustColorTemp(by: prefs.kelvinStep)
        }
    }

    // MARK: - Conversions for the recorder

    /// Converts AppKit modifier flags to the Carbon modifier mask
    /// `RegisterEventHotKey` expects.
    /// Refuses combinations that would hijack standard shortcuts: ⌘ (with or
    /// without ⇧) plus an ordinary key covers ⌘Q, ⌘C, ⌘V, ⌘Tab, ⌘Space and so
    /// on. Adding ⌥ or ⌃, or using a function key, is always allowed.
    static func systemConflict(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                                      kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
                                      kVK_F18, kVK_F19, kVK_F20]
        let onlyCommand = flags.contains(.command) && !flags.contains(.option) && !flags.contains(.control)
        if onlyCommand && !functionKeys.contains(Int(keyCode)) {
            return "⌘ plus a key is used by apps and the system (⌘Q, ⌘C…). Add ⌥ or ⌃."
        }
        return nil
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// Human-readable label for a combo, in the standard macOS order ⌃⌥⇧⌘,
    /// with symbols for keys whose characters aren't printable.
    static func display(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        let special: [Int: String] = [
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_Home: "↖", kVK_End: "↘", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        ]
        return s + (special[Int(keyCode)] ?? (characters ?? "?").uppercased())
    }
}

/// Click, then press the shortcut. Esc cancels, Delete clears.
struct HotkeyRecorder: View {
    /// The action this recorder edits.
    let action: HotkeyAction
    @Bindable var prefs = Preferences.shared
    @State private var recording = false
    /// The local key-down monitor while recording, removed in `stop()`.
    @State private var monitor: Any?
    /// Why the last attempt was refused, or that the shortcut is taken.
    @State private var message: String?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Type shortcut…" : (prefs.hotkeys[action]?.display ?? "Record Shortcut")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 130)
            if let message {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if prefs.hotkeys[action] != nil && !recording {
                Button { prefs.hotkeys[action] = nil; Hotkeys.shared.reload() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear shortcut")
            }
        }
        .onDisappear { if recording { stop() } }
    }

    /// Starts recording: suspends the global shortcuts (so pressing an existing
    /// combo records it instead of firing it) and captures the next key-down.
    private func start() {
        recording = true
        message = nil
        Hotkeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only the four modifiers that matter for a shortcut.
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape: stop()
            case kVK_Delete, kVK_ForwardDelete:
                prefs.hotkeys[action] = nil
                stop()
            default:
                // Require ⌘, ⌥ or ⌃ so plain typing never triggers the light.
                guard !flags.intersection([.command, .option, .control]).isEmpty else {
                    NSSound.beep(); message = "Include ⌘, ⌥ or ⌃."; return nil
                }
                if let clash = Hotkeys.systemConflict(keyCode: event.keyCode, flags: flags) {
                    NSSound.beep(); message = clash; return nil
                }
                message = nil
                prefs.hotkeys[action] = KeyCombo(
                    keyCode: UInt32(event.keyCode), modifiers: Hotkeys.carbonModifiers(flags),
                    display: Hotkeys.display(keyCode: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers))
                stop()
            }
            // Swallow the key either way so it doesn't reach the settings window.
            return nil
        }
    }

    /// Ends recording and re-registers all shortcuts, including a new one.
    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Hotkeys.shared.reload()
        if let reason = Hotkeys.shared.unavailable[action] { message = "This shortcut is \(reason)." }
    }
}
