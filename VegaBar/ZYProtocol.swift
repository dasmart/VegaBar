import Foundation
import os

/// A decoded reply or change event from a light.
///
/// Set commands get no reply, so everything decoded here is either the reply to
/// a read VegaBar sent, or an unsolicited report (heartbeat, a change made on
/// the light itself or by another controller).
enum ZYReply: Equatable {
    /// Brightness in percent (0x1001, f32 at payload offset 3).
    case brightness(id: UInt16, percent: Float)
    /// Colour temperature in Kelvin (0x1002, u16 at payload offset 3).
    case colorTemp(id: UInt16, kelvin: Int)
    /// Power enable state (0x1008): `true` when the light reports 1.
    case power(id: UInt16, on: Bool)
    /// Battery level (0x1201 heartbeat / voltage report), in percent.
    case voltage(id: UInt16, percent: Int)
    /// The connected light's own ZY device id (0x2005). 0x0000 means the light
    /// was never registered.
    case deviceId(UInt16)
    /// Any frame VegaBar doesn't interpret, kept so callers can log it.
    case other(cmd: UInt16, payload: Data)
}

/// ZY light wire protocol (from libzylink.so), written raw to the FEE9 characteristic.
///
/// Frame, little-endian:
///   `24 3C | len u16 | 00 01 | seq u16 | cmd u16 | payload | crc u16`
/// `len` = payload + 6 (covers `00 01`, seq, cmd, payload).
/// `crc` = CRC-16/XMODEM over bytes 4..<end-of-payload.
///
/// Light commands (0x10xx) carry `id u16 | rw u8 (1 set, 0 read) | value`.
/// Device ids are assigned by the controller at registration, starting at 0x8000.
///
/// Hardware findings on a PL103 (verified on the real light, and the reason
/// the encoders below look the way they do):
/// - Control frames go raw and unencrypted to GATT service FEE9. Bluetooth
///   Mesh (services 1827/1828) is used only for provisioning and config.
/// - Set commands get no reply; reads do. In a reply, payload byte 2 is 0.
/// - Brightness must use 0x1001 and colour temperature 0x1002, exactly like the
///   phone app's sliders. The combined 0x100B "brightness + mode" frame did
///   not take effect, so VegaBar never sends it.
/// - 0x1008 is power *enable* (1 = on, 0 = off), despite the SDK naming it
///   "sleep".
/// - Device ids are not mesh unicast addresses; see `firstDeviceId`.
enum ZYProtocol {
    /// The commands VegaBar knows about. This is a small subset of the ZY
    /// protocol; `LightSafety` decides which of these may actually be sent.
    enum Cmd: UInt16 {
        /// Unpair: the light leaves the network. Payload `id u16`.
        case removeDevice = 0x0003
        /// Pairing step: assigns a ZY device id. Payload `id u16 | group u16`.
        case register = 0x0006
        /// Brightness, f32 percent. The only brightness command that works.
        case brightness = 0x1001
        /// Colour temperature, u16 Kelvin. Sent on its own, as the app's slider does.
        case colorTemp = 0x1002
        /// Power enable: 1 = on, 0 = off, in both set frames and read replies.
        /// The SDK calls this "sleep", which misled us at first: its values are
        /// the opposite of what that name suggests.
        case power = 0x1008
        /// Combined brightness + mode. Decoded if a light ever reports it, but
        /// never sent: on the PL103 the frame had no effect.
        case brightnessMode = 0x100B
        /// Blink the light so the user can tell which one it is.
        case identify = 0x1101
        /// Per-device voltage / battery read. The light also sends it as a heartbeat.
        case voltageById = 0x1201
        /// Asks the GATT-connected light (no id needed) for its own device id.
        case getDeviceId = 0x2005
    }


    /// First ZY device id. Ids are handed out by the controller (the phone app,
    /// or VegaBar) from 0x8000 upwards at registration. They are not mesh
    /// unicast addresses; ids below 0x8000 are group ids.
    static let firstDeviceId: UInt16 = 0x8000
    /// Frame sequence counter, starting at 1 like the SDK's. Replies echo the
    /// request's seq; VegaBar doesn't rely on that, but keeps the counter so its
    /// frames match the phone app's byte for byte. Guarded by a lock so it stays
    /// unique whichever thread builds a frame.
    private static let sequence = OSAllocatedUnfairLock<UInt16>(initialState: 1)

    /// Returns the next sequence number. Wraps to 1, never 0, as in the SDK.
    static func nextSequence() -> UInt16 {
        sequence.withLock { s in
            defer { s = s == .max ? 1 : s + 1 }
            return s
        }
    }

    /// Resets the counter; for tests that compare against reference frames.
    static func resetSequence(to value: UInt16 = 1) {
        sequence.withLock { $0 = value }
    }

    // MARK: - Commands

    /// Brightness, as the app's slider sends it (setLight → 0x1001, f32 percent).
    /// Clamped to the safe range here; `LightSafety` re-checks before sending.
    static func setBrightness(device: UInt16, percent: Float) -> Data {
        let p = percent.isFinite ? min(max(percent, LightSafety.brightnessRange.lowerBound),
                                       LightSafety.brightnessRange.upperBound) : percent
        return frame(.brightness, device: device, set: true, value: f32(p))
    }

    /// Colour temperature in Kelvin, as the app's CCT slider sends it (0x1002 alone).
    static func setColorTemp(device: UInt16, kelvin: Int) -> Data {
        let k = min(max(kelvin, LightSafety.kelvinRange.lowerBound), LightSafety.kelvinRange.upperBound)
        return frame(.colorTemp, device: device, set: true, value: u16(UInt16(k)))
    }

    /// Power. The SDK calls 0x1008 "sleep", but the app's caller passes `enable`,
    /// and the light confirms it: 1 = on, 0 = off (reads report the same).
    static func setPower(device: UInt16, on: Bool) -> Data {
        frame(.power, device: device, set: true, value: [on ? 1 : 0])
    }

    /// Reads. These send a zero value of the same size as the set, and the light
    /// replies with the current value (decoded by `Parser`).
    static func getBrightness(device: UInt16) -> Data { frame(.brightness, device: device, set: false, value: [0, 0, 0, 0]) }
    static func getColorTemp(device: UInt16) -> Data { frame(.colorTemp, device: device, set: false, value: [0, 0]) }
    static func getPower(device: UInt16) -> Data { frame(.power, device: device, set: false, value: [0]) }

    /// Battery/voltage of one light (0x1201); the reply is `id u16 | percent u8`.
    static func getVoltage(device: UInt16) -> Data { frame(.voltageById, payload: u16(device)) }
    /// Makes the light blink (0x1101).
    static func identify(device: UInt16) -> Data { frame(.identify, payload: u16(device)) }
    /// Gives the connected light its ZY device id and puts it in `group`
    /// (default group 0). This is the last pairing step, sent once. A light whose
    /// pairing stopped after mesh provisioning reports id 0x0000; sending this
    /// then works and the light acks with status 00.
    static func register(device: UInt16, group: UInt16 = 0) -> Data { frame(.register, payload: u16(device) + u16(group)) }
    /// Tells the light to leave the network (what the phone app's unpair sends).
    static func removeDevice(device: UInt16) -> Data { frame(.removeDevice, payload: u16(device)) }
    /// Asks the connected light for its ZY device id (0x2005, empty payload).
    static func getDeviceId() -> Data { frame(.getDeviceId, payload: []) }

    // MARK: - Framing

    /// A 0x10xx light-command frame: `id u16 | rw u8 (1 set, 0 read) | value`.
    private static func frame(_ cmd: Cmd, device: UInt16, set: Bool, value: [UInt8]) -> Data {
        frame(cmd, payload: u16(device) + [set ? 1 : 0] + value)
    }

    /// Wraps a payload in a complete frame and advances the sequence counter.
    ///
    /// Byte layout of the result (offsets from the start of the frame):
    /// `0-1` magic 24 3C, `2-3` len, `4-5` 00 01, `6-7` seq, `8-9` cmd,
    /// `10…` payload, then 2 CRC bytes. All multi-byte fields are little-endian.
    private static func frame(_ cmd: Cmd, payload: [UInt8]) -> Data {
        let s = nextSequence()
        // Bytes 4… of the frame. `len` counts exactly these (6 + payload).
        var body: [UInt8] = [0x00, 0x01] + u16(s) + u16(cmd.rawValue) + payload
        let header: [UInt8] = [0x24, 0x3C] + u16(UInt16(body.count))
        // CRC covers the body only (00 01 … end of payload), not magic or len.
        body += u16(crc16(body))
        return Data(header + body)
    }

    /// CRC-16/XMODEM: polynomial 0x1021, initial value 0, MSB first, no
    /// reflection, no final XOR (check value for "123456789" is 0x31C3). Matches
    /// the table-driven `zy::crc` in libzylink.so.
    static func crc16(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// Little-endian u16.
    private static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    /// Little-endian IEEE-754 single-precision float.
    private static func f32(_ v: Float) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian, Array.init) }

    // MARK: - Parsing

    /// Reassembles frames from notification chunks. A frame may span several
    /// notifications, or one notification may hold several frames, so incoming
    /// bytes are buffered until a whole frame is present. The parser resyncs on
    /// the 24 3C magic and drops frames with a bad CRC, like the SDK's
    /// `ZYLightParser`.
    struct Parser {
        /// Bytes received but not yet consumed as a complete frame.
        private var buffer: [UInt8] = []

        /// Appends `data` and returns every complete, CRC-valid frame now available.
        mutating func feed(_ data: Data) -> [ZYReply] {
            buffer += data
            var out: [ZYReply] = []
            while true {
                // Discard anything before the next magic. With no magic at all, the
                // buffer holds only noise and is cleared.
                guard let start = magicIndex() else { buffer.removeAll(); break }
                buffer.removeFirst(start)
                // Need magic + len before we know how long the frame is.
                guard buffer.count >= 4 else { break }
                let len = Int(buffer[2]) | Int(buffer[3]) << 8
                // An implausible length means this 24 3C was payload, not a real
                // frame start: skip one byte and search again.
                guard len >= 6, len < 2048 else { buffer.removeFirst(1); continue }
                // magic (2) + len (2) + body (len) + crc (2)
                let total = 4 + len + 2
                // Incomplete: wait for the next notification.
                guard buffer.count >= total else { break }
                // Body = bytes 4..<4+len: 00 01, seq, cmd, payload. Within the body,
                // cmd is at 4-5 and the payload starts at 6.
                let body = Array(buffer[4..<(4 + len)])
                let crc = UInt16(buffer[4 + len]) | UInt16(buffer[5 + len]) << 8
                if crc == ZYProtocol.crc16(body) {
                    buffer.removeFirst(total)
                    let cmd = UInt16(body[4]) | UInt16(body[5]) << 8
                    out.append(ZYProtocol.decode(cmd: cmd, payload: Array(body[6...])))
                } else {
                    // Bad CRC: probably a false magic match. Step past it and resync.
                    buffer.removeFirst(1)
                }
            }
            return out
        }

        /// Index of the first 24 3C, or of a trailing lone 0x24 (the first half of
        /// a magic split across notifications), so it isn't thrown away.
        private func magicIndex() -> Int? {
            guard buffer.count >= 2 else { return buffer.first == 0x24 ? 0 : nil }
            for i in 0..<(buffer.count - 1) where buffer[i] == 0x24 && buffer[i + 1] == 0x3C { return i }
            return buffer.last == 0x24 ? buffer.count - 1 : nil
        }
    }

    /// Decodes one frame's payload. For 0x10xx replies the payload is
    /// `id u16 | byte 2 | value`, with the value at offset 3; byte 2 is 0 in a
    /// read reply. Payloads too short for their command fall through to `.other`.
    static func decode(cmd: UInt16, payload p: [UInt8]) -> ZYReply {
        func u16(_ i: Int) -> UInt16 { UInt16(p[i]) | UInt16(p[i + 1]) << 8 }
        let other = ZYReply.other(cmd: cmd, payload: Data(p))
        switch Cmd(rawValue: cmd) {
        case .brightness where p.count >= 7, .brightnessMode where p.count >= 7:
            let bits = UInt32(p[3]) | UInt32(p[4]) << 8 | UInt32(p[5]) << 16 | UInt32(p[6]) << 24
            return .brightness(id: u16(0), percent: Float(bitPattern: bits))
        case .colorTemp where p.count >= 5:
            return .colorTemp(id: u16(0), kelvin: Int(u16(3)))
        // Read reply (byte 2 = 0). 1 = on, 0 = off, as for the set.
        case .power where p.count >= 4 && p[2] == 0:   // read reply (byte 2 = 0)
            return .power(id: u16(0), on: p[3] != 0)
        // 0x1201: `id u16 | level u8`. AppModel ignores values outside 0-100.
        case .voltageById where p.count >= 3:
            return .voltage(id: u16(0), percent: Int(p[2]))
        case .getDeviceId where p.count >= 2:
            return .deviceId(u16(0))
        default:
            return other
        }
    }
}
