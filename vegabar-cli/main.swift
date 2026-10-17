import AppKit
import Foundation
import Network

/// `vegabar`: a thin command-line client for the VegaBar app.
///
/// It never touches Bluetooth itself. It sends one JSON request over the app's
/// Unix socket and prints the reply, launching the app first if it isn't
/// running. Exit status: 0 success, 1 the app refused the command, 2 bad usage,
/// 3 the app couldn't be reached.

let usage = """
usage: vegabar <command> [value]

  status [--json]          show the light's state
  on | off | toggle        power
  brightness <0-100|±N>    set or nudge brightness (%)
  cct <kelvin|±N>          set or nudge color temperature
  preset <name>            apply a saved preset
  presets                  list presets
  identify                 blink the light

Talks to the running VegaBar app (launching it if needed).
"""

typealias Request = ControlProtocol.Request

// MARK: - Argument parsing

/// Turns argv into a request, or nil for anything unrecognised.
func parse(_ args: [String]) -> (Request, json: Bool)? {
    var args = args
    let json = args.contains("--json")
    args.removeAll { $0 == "--json" }
    guard let cmd = args.first?.lowercased() else { return nil }
    let arg = args.dropFirst().first
    func number(_ c: Request.Command) -> Request? {
        // A leading sign means "nudge by"; reject nan/inf outright.
        guard let arg, let v = Double(arg), v.isFinite else { return nil }
        return Request(command: c, value: v, relative: arg.hasPrefix("+") || arg.hasPrefix("-"))
    }
    switch cmd {
    case "status": return (Request(command: .status), json)
    case "on": return (Request(command: .on), json)
    case "off": return (Request(command: .off), json)
    case "toggle": return (Request(command: .toggle), json)
    case "identify": return (Request(command: .identify), json)
    case "presets": return (Request(command: .presets), json)
    case "brightness", "b": return number(.brightness).map { ($0, json) }
    case "cct", "temp", "k": return number(.cct).map { ($0, json) }
    case "preset", "p":
        guard args.count > 1 else { return nil }
        return (Request(command: .preset, name: args.dropFirst().joined(separator: " ")), json)
    default: return nil
    }
}

// MARK: - Transport

enum SocketError: Error { case unreachable, timeout }

/// Sends one request and waits (synchronously, with a deadline) for the reply.
func exchange(_ request: Request, timeout: TimeInterval) throws -> ControlProtocol.Response {
    let connection = NWConnection(to: .unix(path: ControlProtocol.socketURL.path), using: .tcp)
    let done = DispatchSemaphore(value: 0)
    var result: Result<ControlProtocol.Response, Error> = .failure(SocketError.timeout)
    var received = Data()

    func finish(_ r: Result<ControlProtocol.Response, Error>) {
        result = r
        connection.cancel()
        done.signal()
    }
    func readReply() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data { received.append(data) }
            if received.contains(0x0A) || isComplete || error != nil {
                if let reply = try? JSONDecoder().decode(ControlProtocol.Response.self, from: received) {
                    finish(.success(reply))
                } else {
                    finish(.failure(error ?? SocketError.unreachable))
                }
            } else {
                readReply()
            }
        }
    }

    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            var out = (try? JSONEncoder().encode(request)) ?? Data()
            out.append(0x0A)
            connection.send(content: out, completion: .contentProcessed { error in
                if let error { finish(.failure(error)) } else { readReply() }
            })
        case .failed(let error): finish(.failure(error))
        case .waiting: finish(.failure(SocketError.unreachable))   // nobody listening
        default: break
        }
    }
    connection.start(queue: DispatchQueue(label: "vegabar.cli"))
    guard done.wait(timeout: .now() + timeout) == .success else {
        connection.cancel()
        throw SocketError.timeout
    }
    return try result.get()
}

/// Launches the VegaBar.app this tool is embedded in (Contents/Helpers/vegabar),
/// in the background. The tool's real path is used, not argv[0], which is just
/// "vegabar" when the shell found it on the PATH. Falls back to the bundle id.
func launchApp() {
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let embedding = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let app = embedding.pathExtension == "app" ? embedding
        : NSWorkspace.shared.urlForApplication(withBundleIdentifier: ControlProtocol.appBundleIdentifier)
    guard let app else { return }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: app, configuration: config) { _, _ in done.signal() }
    _ = done.wait(timeout: .now() + 10)
}

/// Sends the request, launching the app and retrying for a few seconds if it
/// wasn't running.
func send(_ request: Request) -> ControlProtocol.Response? {
    if let r = try? exchange(request, timeout: 25) { return r }
    launchApp()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        usleep(250_000)
        if let r = try? exchange(request, timeout: 25) { return r }
    }
    return nil
}

// MARK: - Output

func describe(_ s: ControlProtocol.Status) -> String {
    var parts = ["\(s.light ?? "Light"): \(s.connected ? (s.on ? "on" : "off") : "not connected")"]
    if s.connected {
        parts.append("\(s.brightness)%")
        parts.append("\(s.colorTemperature)K")
        if let b = s.battery { parts.append("battery \(b)%") }
    }
    return parts.joined(separator: ", ")
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("vegabar: \(message)\n".utf8))
    exit(code)
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(args.isEmpty ? 2 : 0)
}
guard let (request, json) = parse(args) else { fail("unrecognised command\n\n\(usage)", code: 2) }
guard let response = send(request) else { fail("couldn't reach the VegaBar app", code: 3) }

if json {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: (try? enc.encode(response)) ?? Data(), as: UTF8.self))
} else if !response.ok {
    FileHandle.standardError.write(Data("vegabar: \(response.error ?? "failed")\n".utf8))
} else if request.command == .presets {
    print((response.status?.presets ?? []).joined(separator: "\n"))
} else if let s = response.status {
    print(describe(s))
}
exit(response.ok ? 0 : 1)
