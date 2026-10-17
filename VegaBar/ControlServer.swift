import Foundation
import Network

/// Local control endpoint for the `vegabar` CLI (and anything else that can
/// write a line of JSON to a Unix socket), built on Network.framework.
///
/// Protocol: a client connects, sends one JSON `ControlProtocol.Request`
/// terminated by a newline, and reads back one JSON `Response` line, after
/// which the server closes the connection. One request per connection keeps
/// both sides trivial.
///
/// Access control is the file system's: the socket lives in a directory only
/// this user can enter (`~/Library/Application Support/VegaBar`, mode 0700, or
/// in the App Store build the App Group container shared with the CLI)
/// and is itself mode 0600, so other accounts on the Mac can't reach it. Any
/// process running as this user can, which is the intended audience: scripts,
/// Stream Deck, Raycast. What they can do is limited to `ControlProtocol`'s
/// commands — there is no way to unpair or register over the socket — and
/// every resulting frame still passes `LightSafety`.
///
/// Everything runs on the main queue: requests are tiny and `AppModel` is
/// main-actor isolated anyway, so this needs no locking.
@MainActor
final class ControlServer {
    private let model: AppModel
    private var listener: NWListener?
    /// Longest request line accepted; anything bigger is a bug or an attack.
    nonisolated private static let maxRequestBytes = 64 * 1024

    init(model: AppModel) { self.model = model }

    func start() {
        let socketURL = ControlProtocol.socketURL
        let dir = socketURL.deletingLastPathComponent()
        let fm = FileManager.default
        // Create the directory private-to-user *before* the socket appears in it,
        // so there is never a moment when another account could connect.
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // A socket file left by a previous run (or a crash) would block binding.
        try? fm.removeItem(at: socketURL)

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: socketURL.path)
        do {
            listener = try NWListener(using: params)
        } catch {
            Log.error(.control, "couldn't create control socket: \(error.localizedDescription)")
            return
        }
        listener?.stateUpdateHandler = { state in
            let fm = FileManager.default
            switch state {
            case .ready:
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socketURL.path)
                Log.info(.control, "listening on \(socketURL.path)")
            case .failed(let error):
                Log.error(.control, "control socket failed: \(error.localizedDescription)")
            default: break
            }
        }
        // The listener runs on the main queue, so this is already main-actor code.
        listener?.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.serve(connection) }
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: ControlProtocol.socketURL)
    }

    // MARK: - One connection

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        Self.receiveLine(connection, buffer: Data()) { [weak self] line in
            guard let self else { return connection.cancel() }
            Task { @MainActor in
                let response: ControlProtocol.Response
                if let line, let request = try? JSONDecoder().decode(ControlProtocol.Request.self, from: line) {
                    response = await self.model.perform(request)
                } else {
                    response = .init(ok: false, error: "Malformed request.")
                }
                var out = (try? JSONEncoder().encode(response)) ?? Data()
                out.append(0x0A)   // newline tells the client the reply is complete
                connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// Accumulates bytes until the first newline, EOF, or the size cap, then
    /// hands the line to `completion` on the main actor. Nonisolated because
    /// Network.framework's callbacks are `@Sendable`; they are delivered on the
    /// main queue (`connection.start(queue: .main)`), so hopping is free.
    nonisolated private static func receiveLine(_ connection: NWConnection, buffer: Data,
                                                completion: @escaping @MainActor @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                MainActor.assumeIsolated { completion(line) }
            } else if isComplete || error != nil || buffer.count > maxRequestBytes {
                let line: Data? = buffer.isEmpty || buffer.count > maxRequestBytes ? nil : buffer
                MainActor.assumeIsolated { completion(line) }
            } else {
                receiveLine(connection, buffer: buffer, completion: completion)
            }
        }
    }
}
