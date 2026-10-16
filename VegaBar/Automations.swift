import AppKit
import CoreMediaIO
import ServiceManagement

/// Background behaviours: camera-driven power, following Mac sleep/lock, and
/// the optional time-of-day colour temperature.
///
/// All of it is event-driven. Camera use comes from CoreMediaIO property
/// listeners (with a slow safety-net check), sleep and lock from system
/// notifications, and the colour schedule from a once-a-minute timer with a
/// generous tolerance, so an idle VegaBar wakes the CPU as little as possible.
@MainActor
final class Automations {
    static let shared = Automations(model: .shared, prefs: .shared)
    private let model: AppModel
    private let prefs: Preferences

    init(model: AppModel, prefs: Preferences) {
        self.model = model
        self.prefs = prefs
    }

    // Camera
    private var cameraActive = false
    /// What the camera automation changed, so it can be undone when the camera
    /// stops: whether it turned the light on, and the brightness/colour it
    /// replaced when it applied a preset.
    private var cameraChanges: (turnedOn: Bool, previous: (brightness: Double, cct: Double)?)?
    private var cameraListeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var cameraFallbackTimer: Timer?

    /// Power state to restore after sleep / lock (set only if we turned it off).
    private var restorePowerOnWake = false

    // Colour schedule
    private var colorTimer: Timer?
    private var colorPausedUntil: Date?

    func start() {
        installCameraListeners()
        // Safety net in case a listener is missed (e.g. a virtual camera that
        // doesn't post property changes). Cheap, and tolerant so it coalesces.
        cameraFallbackTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { Automations.shared.evaluateCamera() }
        }
        cameraFallbackTimer?.tolerance = 10

        colorTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { Automations.shared.applyColorSchedule() }
        }
        colorTimer?.tolerance = 20

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Automations.shared.macWillSleep(reason: .sleep) }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Automations.shared.macDidWake() }
        }
        // Lock/unlock are only announced on the distributed centre.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Automations.shared.macWillSleep(reason: .lock) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Automations.shared.macDidWake() }
        }

        model.onManualColorTemp = { [weak self] in self?.pauseColorSchedule() }
        model.onConnected = { [weak self] in self?.applyColorSchedule() }
    }

    // MARK: - Camera

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    /// Every CoreMediaIO device (built-in, USB and Continuity cameras).
    private static func cameraDevices() -> [CMIOObjectID] {
        var addr = address(kCMIOHardwarePropertyDevices)
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == noErr else { return [] }
        return devices
    }

    /// True while any camera is streaming to any app. Reading this property
    /// needs no camera permission; it says nothing about the picture.
    static func anyCameraRunning() -> Bool {
        var running = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for device in cameraDevices() {
            var value: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &value) == noErr,
               value != 0 {
                return true
            }
        }
        return false
    }

    /// Listens for "is running somewhere" changes on every camera, and for the
    /// device list itself so cameras plugged in later are covered too.
    private func installCameraListeners() {
        var devicesAddr = Self.address(kCMIOHardwarePropertyDevices)
        let onDevicesChanged: CMIOObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Automations.shared.refreshCameraListeners() } }
        }
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devicesAddr, .main, onDevicesChanged)
        refreshCameraListeners()
    }

    private func refreshCameraListeners() {
        var running = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        let current = Set(Self.cameraDevices())
        for (device, block) in cameraListeners where !current.contains(device) {
            CMIOObjectRemovePropertyListenerBlock(device, &running, .main, block)
            cameraListeners[device] = nil
        }
        for device in current where cameraListeners[device] == nil {
            let block: CMIOObjectPropertyListenerBlock = { _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { Automations.shared.evaluateCamera() } }
            }
            if CMIOObjectAddPropertyListenerBlock(device, &running, .main, block) == noErr {
                cameraListeners[device] = block
            }
        }
        evaluateCamera()
    }

    /// Reacts to a change in whether any camera is in use.
    private func evaluateCamera() {
        guard prefs.cameraAutoOn else {
            cameraActive = false
            cameraChanges = nil
            return
        }
        let active = Self.anyCameraRunning()
        guard active != cameraActive else { return }
        cameraActive = active
        Log.info(.automation, "camera \(active ? "started" : "stopped")")
        if active {
            Task {
                guard await model.waitUntilConnected() else { return }
                let turnedOn = !model.isOn
                var previous: (Double, Double)?
                if let id = prefs.cameraPresetId, let preset = prefs.presets.first(where: { $0.id == id }) {
                    previous = (model.brightness, model.cct)
                    model.applyPreset(preset)
                } else if turnedOn {
                    model.setPower(true)
                }
                cameraChanges = (turnedOn, previous)
            }
        } else if let changes = cameraChanges {
            cameraChanges = nil
            guard prefs.cameraAutoOff, model.isConnected else { return }
            // Put back what we changed: the previous look first (so the light
            // doesn't flash the call preset next time it's turned on), then power.
            if let previous = changes.previous, model.isOn {
                model.setBrightness(previous.brightness)
                model.setCCT(previous.cct, byAutomation: true)
            }
            if changes.turnedOn { model.setPower(false) }
        }
    }

    // MARK: - Sleep / lock

    private enum OffReason { case sleep, lock }

    private func macWillSleep(reason: OffReason) {
        let enabled = reason == .sleep ? prefs.offWhenMacSleeps : prefs.offWhenScreenLocks
        guard enabled, model.isConnected, model.isOn else { return }
        Log.info(.automation, "mac \(reason == .sleep ? "sleeping" : "locked"): turning light off")
        restorePowerOnWake = true
        model.setPower(false)
    }

    private func macDidWake() {
        guard restorePowerOnWake else { return }
        restorePowerOnWake = false
        Log.info(.automation, "mac awake/unlocked: restoring light")
        Task {
            // The Bluetooth link usually drops during sleep; wait for it to return.
            if await model.waitUntilConnected(timeout: .seconds(30)) { model.setPower(true) }
        }
    }

    // MARK: - Time-of-day colour temperature

    /// Minutes either side of each start time over which the colour blends.
    nonisolated static let ramp = 30

    /// Target Kelvin for a minute of the day: `day` between the morning and
    /// evening starts, `night` otherwise, blended linearly over the hour
    /// centred on each start. Pure, so it's unit-tested directly.
    nonisolated static func targetKelvin(minuteOfDay m: Int, day: Double, night: Double,
                             morningStart: Int, eveningStart: Int) -> Double {
        func blend(_ from: Double, _ to: Double, start: Int) -> Double? {
            // Minutes since this window opened, wrapped so windows that straddle
            // midnight work.
            let t = Double(((m - (start - ramp)) % 1440 + 1440) % 1440)
            guard t <= Double(2 * ramp) else { return nil }
            return from + (to - from) * t / Double(2 * ramp)
        }
        if let k = blend(night, day, start: morningStart) { return k }
        if let k = blend(day, night, start: eveningStart) { return k }
        let inDay = morningStart < eveningStart
            ? (m > morningStart && m < eveningStart)
            : !(m > eveningStart && m < morningStart)
        return inDay ? day : night
    }

    func targetKelvin(at date: Date = Date()) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Self.targetKelvin(minuteOfDay: (c.hour ?? 0) * 60 + (c.minute ?? 0),
                                 day: prefs.dayKelvin, night: prefs.eveningKelvin,
                                 morningStart: prefs.morningStart, eveningStart: prefs.eveningStart)
    }

    private func applyColorSchedule() {
        guard prefs.autoColorTemp, model.isConnected, model.isOn else { return }
        if let until = colorPausedUntil, Date() < until { return }
        colorPausedUntil = nil
        let target = (targetKelvin() / 50).rounded() * 50
        if abs(target - model.cct) >= 25 { model.setCCT(target, byAutomation: true) }
    }

    /// A manual change wins until the schedule's next transition begins.
    private func pauseColorSchedule() {
        guard prefs.autoColorTemp else { return }
        let cal = Calendar.current, now = Date()
        // The schedule resumes when the next blend window opens (start - ramp),
        // i.e. the earlier of the next morning and evening windows. `begin` is
        // wrapped into 0..<1440 first, so a start before 00:30 correctly maps to
        // the previous evening (e.g. 00:15 - 30 min = 23:45).
        let next = [prefs.morningStart, prefs.eveningStart].compactMap { start -> Date? in
            let begin = ((start - Self.ramp) % 1440 + 1440) % 1440
            return cal.nextDate(after: now, matching: DateComponents(hour: begin / 60, minute: begin % 60),
                                matchingPolicy: .nextTime)
        }.min()
        colorPausedUntil = next
        Log.info(.automation, "auto color temp paused until \(next.map { "\($0)" } ?? "?")")
    }

    func resumeColorSchedule() {
        colorPausedUntil = nil
        applyColorSchedule()
    }

    var isColorSchedulePaused: Bool { colorPausedUntil.map { Date() < $0 } ?? false }
}

/// Launch at login via the system Login Items list (SMAppService), which the
/// user can also see and change in System Settings.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
