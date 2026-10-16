import Foundation

/// The last line of defence between VegaBar and the light.
///
/// Every frame — whether it came from a slider, a hotkey, Shortcuts, the CLI, a
/// `vegabar://` URL or an automation — passes through `validate(_:)` inside
/// `ZYLink.send` immediately before it is written over Bluetooth. A frame that
/// fails any rule is dropped and logged; it never reaches the light.
///
/// The rules are deliberately conservative:
///
/// 1. **Allow-list of commands.** Only the handful of commands VegaBar needs can
///    be sent. Everything else the ZY protocol supports is refused outright,
///    notably 0x1009 "max mode" (an overdrive setting), firmware update, factory
///    test and effect/animation uploads — none of which VegaBar uses, and any of
///    which could stress or brick a light if sent incorrectly.
/// 2. **Exact payload shapes.** Each allowed command must have exactly the
///    payload length it is defined with, so a malformed frame can't be
///    misinterpreted by the firmware.
/// 3. **Value ranges.** Brightness must be a finite number from 0 to 100 %,
///    colour temperature must be inside the light's supported range, power must
///    be exactly 0 or 1, and device ids must be real device ids (0x8000+).
/// 4. **Integrity.** Magic, length and CRC are re-checked, guarding against a
///    bug in the encoder producing a frame the light would mis-parse.
///
/// Rate limiting (how *often* frames may be sent) is enforced separately by
/// `ZYLink`, using the limits defined here.
enum LightSafety {
    // MARK: Limits

    /// Brightness the light accepts, in percent.
    static let brightnessRange: ClosedRange<Float> = 0...100

    /// Colour temperature range of the PL103 (bi-colour), in Kelvin. The light
    /// reported values at both ends (2700K, 3600K) during testing; 6500K is the
    /// upper end of Zhiyun's bi-colour range. Values outside are never sent.
    static let kelvinRange: ClosedRange<Int> = 2700...6500

    /// Device ids are assigned from 0x8000 upwards at registration; anything
    /// lower is a group id or "unregistered" (0), which VegaBar never targets.
    static let deviceIdRange: ClosedRange<UInt16> = 0x8000...0xFFFE

    /// Never more than this many frames per second leave the Mac. Sliders and
    /// scrolling are coalesced well below this; it caps runaway scripts.
    static let maxFramesPerSecond: Double = 20

    /// Frames waiting to be sent beyond this are dropped (newest first), so a
    /// flood can't build an ever-growing backlog that plays out for minutes.
    static let maxQueuedFrames = 32

    /// Minimum spacing between consecutive *writes* of the same command.
    ///
    /// These are the anti-strobe caps: whatever a script or automation asks for,
    /// brightness and colour can't change faster than 10 Hz and power can't
    /// cycle faster than once a second. (The slider throttle is 80 ms, so the
    /// coalescing queue, where the newest value wins, keeps the sliders smooth.)
    /// Reads are not spaced, because they can't change anything.
    static func minInterval(for cmd: ZYProtocol.Cmd, isWrite: Bool) -> TimeInterval? {
        guard isWrite else { return nil }
        switch cmd {
        case .brightness, .brightnessMode, .colorTemp: return 0.1   // ≤ 10 changes per second
        case .power: return 1.0                     // ≤ 1 on/off cycle per second
        case .identify, .register, .removeDevice: return 2.0   // one-off actions
        case .voltageById, .getDeviceId: return nil
        }
    }

    // MARK: Validation

    /// Result of `validate(_:)`: allowed, or rejected with a reason for the log.
    enum Verdict: Equatable {
        case allowed
        case rejected(String)
    }

    /// Checks one complete frame against every rule above.
    static func validate(_ frame: Data) -> Verdict {
        let b = [UInt8](frame)

        // Integrity: magic, declared length, and CRC must all agree.
        guard b.count >= 12, b[0] == 0x24, b[1] == 0x3C else { return .rejected("bad header") }
        let len = Int(b[2]) | Int(b[3]) << 8
        guard b.count == 4 + len + 2, len >= 6 else { return .rejected("length mismatch") }
        let body = Array(b[4..<(4 + len)])
        let crc = UInt16(b[4 + len]) | UInt16(b[5 + len]) << 8
        guard crc == ZYProtocol.crc16(body) else { return .rejected("bad CRC") }

        // Allow-list.
        let rawCmd = UInt16(body[4]) | UInt16(body[5]) << 8
        guard let cmd = ZYProtocol.Cmd(rawValue: rawCmd), let rule = rules[cmd] else {
            return .rejected(String(format: "command 0x%04X is not allowed", rawCmd))
        }

        // Exact payload shape, then the command's own value checks.
        let payload = Array(body[6...])
        guard payload.count == rule.payloadLength else {
            return .rejected("\(cmd) payload is \(payload.count) bytes, expected \(rule.payloadLength)")
        }
        return rule.check(payload)
    }

    // MARK: Per-command rules

    /// What one allowed command must look like: its exact payload length (bytes
    /// after the cmd field) and a check of the values in it.
    private struct Rule: Sendable {
        let payloadLength: Int
        let check: @Sendable ([UInt8]) -> Verdict
    }

    /// Little-endian readers over a payload, matching the encoder in `ZYProtocol`.
    private static func u16(_ p: [UInt8], _ i: Int) -> UInt16 { UInt16(p[i]) | UInt16(p[i + 1]) << 8 }

    private static func f32(_ p: [UInt8], _ i: Int) -> Float {
        Float(bitPattern: UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24)
    }

    /// The target id must be a registered device, not a group / broadcast.
    private static func checkDevice(_ p: [UInt8]) -> Verdict? {
        deviceIdRange.contains(u16(p, 0)) ? nil : .rejected(String(format: "device id 0x%04X out of range", u16(p, 0)))
    }

    /// For 0x10xx light commands byte 2 is read (0) / write (1).
    private static func checkRW(_ p: [UInt8]) -> Verdict? {
        p[2] <= 1 ? nil : .rejected("bad read/write flag \(p[2])")
    }

    /// Reads must send an all-zero value; only writes carry data.
    private static func isRead(_ p: [UInt8]) -> Bool { p[2] == 0 }

    /// The allow-list itself: a command missing from this table is refused.
    private static let rules: [ZYProtocol.Cmd: Rule] = [
        // Brightness: id, rw, f32 percent.
        .brightness: Rule(payloadLength: 7) { p in
            if let v = checkDevice(p) ?? checkRW(p) { return v }
            if isRead(p) { return p[3...].allSatisfy { $0 == 0 } ? .allowed : .rejected("read with data") }
            let value = f32(p, 3)
            guard value.isFinite, brightnessRange.contains(value) else { return .rejected("brightness \(value) out of range") }
            return .allowed
        },
        // Colour temperature: id, rw, u16 Kelvin.
        .colorTemp: Rule(payloadLength: 5) { p in
            if let v = checkDevice(p) ?? checkRW(p) { return v }
            if isRead(p) { return u16(p, 3) == 0 ? .allowed : .rejected("read with data") }
            let k = Int(u16(p, 3))
            return kelvinRange.contains(k) ? .allowed : .rejected("colour temperature \(k)K out of range")
        },
        // Power: id, rw, u8 (1 = on, 0 = off). 0x1008 is power *enable*, whatever
        // the SDK's "sleep" name suggests; confirmed on the PL103.
        .power: Rule(payloadLength: 4) { p in
            if let v = checkDevice(p) ?? checkRW(p) { return v }
            return p[3] <= 1 ? .allowed : .rejected("power value \(p[3])")
        },
        // Identify (blink) and battery read: id only.
        .identify: Rule(payloadLength: 2) { p in checkDevice(p) ?? .allowed },
        .voltageById: Rule(payloadLength: 2) { p in checkDevice(p) ?? .allowed },
        // Ask the connected light for its id: no payload.
        .getDeviceId: Rule(payloadLength: 0) { _ in .allowed },
        // Register: id, group. VegaBar only ever uses the default group 0.
        .register: Rule(payloadLength: 4) { p in
            if let v = checkDevice(p) { return v }
            return u16(p, 2) == 0 ? .allowed : .rejected("register into group \(u16(p, 2))")
        },
        // Unpair: id only. (Also gated behind a confirmation dialog in the UI.)
        .removeDevice: Rule(payloadLength: 2) { p in checkDevice(p) ?? .allowed },
    ]
}
