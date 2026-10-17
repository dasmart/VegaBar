import Foundation
import os

/// Puts the `vegabar` tool bundled in VegaBar.app onto the user's PATH as a
/// symlink, so the tool updates whenever the app does.
///
/// Where it goes depends on the Mac, not on any one package manager:
/// 1. If a `vegabar` is already on the user's PATH, that one is reused: left
///    alone when it already points at this app (a Homebrew cask install links
///    it this way), or repointed when it's a link to an older copy.
/// 2. Otherwise the first conventional bin folder on the user's PATH that can
///    be written without a password: Homebrew's, `~/.local/bin` or `~/bin`.
/// 3. Otherwise `/usr/local/bin`, which every Mac's default PATH includes
///    (`/etc/paths`), after the standard macOS administrator prompt.
///
/// The PATH is read from the user's login shell, because an app launched from
/// the Dock or at login only sees a minimal one.
enum CLIInstaller {
    /// What the installer will do. Computed by `plan`, which has no side
    /// effects, so every case can be unit-tested.
    enum Plan: Equatable {
        /// A link at this path already points at this app's tool.
        case alreadyInstalled(link: String)
        /// Create (or repoint) the link in a folder the user can write.
        case link(directory: String)
        /// Create (or repoint) the link with administrator rights.
        case linkAsAdmin(directory: String)
        /// A file that isn't a symlink already has the name; never overwritten.
        case blocked(path: String)
    }

    /// What exists at a candidate link path.
    enum Existing: Equatable {
        case nothing
        /// A symlink, with the absolute path it finally resolves to.
        case symlink(resolvedTo: String)
        /// A real file or folder.
        case file
    }

    /// The folder used when nothing writable is on the PATH. It's in
    /// `/etc/paths`, so every login shell has it.
    static let systemDirectory = "/usr/local/bin"

    /// Conventional folders for user-installed command-line tools. Anything
    /// else on the PATH (app bundles, language managers) is never written to.
    static func conventionalDirectories(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"]
    }

    /// Decides where the link goes.
    ///
    /// - parameters:
    ///   - pathDirectories: the user's PATH, in order.
    ///   - home: the user's home folder.
    ///   - tool: the resolved path of the tool inside this app.
    ///   - existing: what is at a given link path.
    ///   - isWritableDirectory: whether a folder exists and the user can write it.
    static func plan(pathDirectories: [String], home: String, tool: String,
                     existing: (String) -> Existing,
                     isWritableDirectory: (String) -> Bool) -> Plan {
        let conventional = conventionalDirectories(home: home)
        var candidates: [String] = []
        for dir in pathDirectories.map({ normalize($0, home: home) })
        where conventional.contains(dir) && !candidates.contains(dir) {
            candidates.append(dir)
        }
        if !candidates.contains(systemDirectory) { candidates.append(systemDirectory) }

        // 1. Reuse a vegabar already on the PATH. The first one wins, because
        //    that is the one the shell runs.
        for dir in candidates {
            let link = "\(dir)/vegabar"
            switch existing(link) {
            case .nothing: continue
            case .file: return .blocked(path: link)
            case .symlink(let target) where target == tool: return .alreadyInstalled(link: link)
            case .symlink:
                return isWritableDirectory(dir) ? .link(directory: dir) : .linkAsAdmin(directory: dir)
            }
        }
        // 2. The first folder on the PATH that needs no password.
        if let dir = candidates.first(where: isWritableDirectory) { return .link(directory: dir) }
        // 3. The system folder, with an administrator prompt.
        return .linkAsAdmin(directory: systemDirectory)
    }

    /// Expands `~` and drops a trailing slash so PATH entries compare cleanly.
    static func normalize(_ dir: String, home: String) -> String {
        var d = dir
        if d == "~" { d = home } else if d.hasPrefix("~/") { d = home + d.dropFirst() }
        while d.count > 1 && d.hasSuffix("/") { d.removeLast() }
        return d
    }

    // MARK: - Doing it

    /// Installs the tool and returns a message for the Settings window.
    static func install() async -> String {
        let fm = FileManager.default
        let toolURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vegabar")
        guard fm.isExecutableFile(atPath: toolURL.path) else {
            return "The command-line tool is missing from VegaBar.app."
        }
        // An app opened straight from Downloads may be running from a temporary,
        // randomised copy (App Translocation). A link to it would break.
        if toolURL.path.contains("/AppTranslocation/") {
            return "Move VegaBar to your Applications folder and open it from there, then install the command-line tool."
        }
        let tool = toolURL.resolvingSymlinksInPath().path
        let home = fm.homeDirectoryForCurrentUser.path
        let path = await UserShell.path() ?? fallbackPath()

        let plan = plan(pathDirectories: path, home: home, tool: tool,
                        existing: existingItem(at:), isWritableDirectory: isWritableDirectory)
        Log.info(.app, "CLI install plan: \(plan)")
        switch plan {
        case .alreadyInstalled(let link):
            return "Already installed: \(link). Try: vegabar status"
        case .blocked(let path):
            return "\(path) already exists and isn't a link to VegaBar. Remove or rename it, then try again."
        case .link(let dir):
            let link = "\(dir)/vegabar"
            do {
                if case .symlink = existingItem(at: link) { try fm.removeItem(atPath: link) }
                try fm.createSymbolicLink(atPath: link, withDestinationPath: tool)
                return "Installed \(link). Open a new Terminal window, then try: vegabar status"
            } catch {
                return "Couldn't create \(link): \(error.localizedDescription)"
            }
        case .linkAsAdmin(let dir):
            return await linkAsAdmin(tool: tool, directory: dir)
        }
    }

    /// Creates the link with administrator rights, through the standard macOS
    /// password prompt. The paths go to the script as arguments, never pasted
    /// into its source, so nothing in them can change what runs.
    private static func linkAsAdmin(tool: String, directory: String) async -> String {
        let link = "\(directory)/vegabar"
        let script = [
            "on run argv",
            "set tool to quoted form of item 1 of argv",
            "set dir to quoted form of item 2 of argv",
            "set lnk to quoted form of item 3 of argv",
            "set cmd to \"/bin/mkdir -p \" & dir & \" && /bin/ln -sfn \" & tool & \" \" & lnk",
            "set msg to \"VegaBar wants to install its command-line tool in \" & item 2 of argv & \".\"",
            "do shell script cmd with prompt msg with administrator privileges",
            "end run",
        ]
        let result = await run("/usr/bin/osascript", script.flatMap { ["-e", $0] } + [tool, directory, link], timeout: 300)
        if result.status == 0 { return "Installed \(link). Open a new Terminal window, then try: vegabar status" }
        // -128 is "User canceled".
        if result.output.contains("-128") {
            return "Not installed. To install it yourself, run: sudo ln -sf \"\(tool)\" \(link)"
        }
        return "Couldn't install \(link) (\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))). Run: sudo ln -sf \"\(tool)\" \(link)"
    }

    private static func existingItem(at path: String) -> Existing {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return .nothing }
        guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { return .file }
        return .symlink(resolvedTo: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    private static func isWritableDirectory(_ dir: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
            && FileManager.default.isWritableFile(atPath: dir)
    }

    /// Used when the login shell can't be read: what `path_helper` gives every
    /// login shell (`/etc/paths` and `/etc/paths.d`), with Homebrew's folder
    /// first when it exists, as `brew shellenv` arranges.
    static func fallbackPath() -> [String] {
        var dirs: [String] = []
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin") { dirs.append("/opt/homebrew/bin") }
        var files = ["/etc/paths"]
        if let extra = try? FileManager.default.contentsOfDirectory(atPath: "/etc/paths.d") {
            files += extra.sorted().map { "/etc/paths.d/\($0)" }
        }
        for file in files {
            let lines = (try? String(contentsOfFile: file, encoding: .utf8))?.split(separator: "\n") ?? []
            dirs += lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return dirs
    }
}

/// The user's login-shell PATH, which a GUI app doesn't inherit.
enum UserShell {
    /// Runs the user's shell as an interactive login shell (so it reads the
    /// same startup files Terminal does) and prints PATH between markers, so
    /// anything else the startup files print is ignored. Nil if that fails or
    /// takes more than 5 seconds.
    static func path() async -> [String]? {
        let shell = loginShell()
        let marker = "__VEGABAR_PATH__"
        let result = await run(shell, ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""], timeout: 5)
        guard result.status == 0,
              let start = result.output.range(of: marker),
              let end = result.output.range(of: marker, range: start.upperBound..<result.output.endIndex)
        else {
            Log.info(.app, "couldn't read the login shell's PATH from \(shell)")
            return nil
        }
        let value = result.output[start.upperBound..<end.lowerBound]
        // fish joins a quoted PATH with spaces; every other shell uses colons.
        let separator: Character = value.contains(":") || !value.contains(" ") ? ":" : " "
        let dirs = value.split(separator: separator).map(String.init).filter { !$0.isEmpty }
        return dirs.isEmpty ? nil : dirs
    }

    /// The shell from the user's account record, which is what Terminal uses.
    private static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let s = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }
}

/// Runs a program off the main thread with no input, collecting its output
/// and error text. The program is terminated if it outlives `timeout` seconds.
///
/// Output is gathered as it arrives rather than read to end-of-file: a shell's
/// startup files can leave a background process holding the pipe open, and
/// waiting for that would never finish.
private func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> (status: Int32, output: String) {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = OSAllocatedUnfairLock(initialState: Data())
            let eof = DispatchSemaphore(value: 0)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { eof.signal() } else { buffer.withLock { $0.append(chunk) } }
            }
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do { try process.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: (-1, error.localizedDescription))
                return
            }
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                _ = exited.wait(timeout: .now() + 1)
            }
            // Give the last output a moment to arrive, but don't wait on a
            // pipe some leftover child still holds open.
            _ = eof.wait(timeout: .now() + 0.5)
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = process.isRunning ? -1 : process.terminationStatus
            cont.resume(returning: (status, String(decoding: buffer.withLock { $0 }, as: UTF8.self)))
        }
    }
}
