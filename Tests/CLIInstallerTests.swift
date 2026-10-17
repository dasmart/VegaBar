import XCTest
@testable import VegaBar

/// Where the command-line tool goes on differently set-up Macs.
final class CLIInstallerTests: XCTestCase {
    private let home = "/Users/me"
    private let tool = "/Applications/VegaBar.app/Contents/Helpers/vegabar"
    /// A stock macOS PATH, from /etc/paths.
    private let stockPath = ["/usr/local/bin", "/System/Cryptexes/App/usr/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private func plan(path: [String], writable: Set<String>,
                      existing: [String: CLIInstaller.Existing] = [:]) -> CLIInstaller.Plan {
        CLIInstaller.plan(pathDirectories: path, home: home, tool: tool,
                          existing: { existing[$0] ?? .nothing },
                          isWritableDirectory: { writable.contains($0) })
    }

    func testStockMacWithoutHomebrewUsesUsrLocalBinWithAdmin() {
        // /usr/local/bin is missing or root-owned, and nothing else is on the PATH.
        XCTAssertEqual(plan(path: stockPath, writable: []), .linkAsAdmin(directory: "/usr/local/bin"))
    }

    func testAppleSiliconHomebrewNeedsNoPassword() {
        let path = ["/opt/homebrew/bin", "/opt/homebrew/sbin"] + stockPath
        XCTAssertEqual(plan(path: path, writable: ["/opt/homebrew/bin"]), .link(directory: "/opt/homebrew/bin"))
    }

    func testIntelHomebrewOwnsUsrLocalBin() {
        XCTAssertEqual(plan(path: stockPath, writable: ["/usr/local/bin"]), .link(directory: "/usr/local/bin"))
    }

    func testUsersOwnBinFolderOnThePathIsUsed() {
        let path = ["~/.local/bin"] + stockPath
        XCTAssertEqual(plan(path: path, writable: ["\(home)/.local/bin"]), .link(directory: "\(home)/.local/bin"))
    }

    func testHomeFolderNotOnThePathIsIgnored() {
        // Writable, but the shell wouldn't find the tool there.
        XCTAssertEqual(plan(path: stockPath, writable: ["\(home)/.local/bin"]),
                       .linkAsAdmin(directory: "/usr/local/bin"))
    }

    func testOtherWritablePathFoldersAreNeverUsed() {
        let path = ["\(home)/Library/pnpm", "/Applications/Tool.app/Contents/Public"] + stockPath
        XCTAssertEqual(plan(path: path, writable: ["\(home)/Library/pnpm", "/Applications/Tool.app/Contents/Public"]),
                       .linkAsAdmin(directory: "/usr/local/bin"))
    }

    func testFirstMatchingFolderInPathOrderWins() {
        let path = ["\(home)/bin", "/opt/homebrew/bin"] + stockPath
        XCTAssertEqual(plan(path: path, writable: ["\(home)/bin", "/opt/homebrew/bin"]), .link(directory: "\(home)/bin"))
    }

    func testCaskInstalledLinkIsRecognised() {
        let path = ["/opt/homebrew/bin"] + stockPath
        XCTAssertEqual(plan(path: path, writable: ["/opt/homebrew/bin"],
                            existing: ["/opt/homebrew/bin/vegabar": .symlink(resolvedTo: tool)]),
                       .alreadyInstalled(link: "/opt/homebrew/bin/vegabar"))
    }

    func testLinkToAnOldCopyIsRepointedWhereItIs() {
        let old = CLIInstaller.Existing.symlink(resolvedTo: "/Users/me/Downloads/VegaBar.app/Contents/Helpers/vegabar")
        // In a writable folder: no password needed.
        XCTAssertEqual(plan(path: stockPath, writable: ["/usr/local/bin"], existing: ["/usr/local/bin/vegabar": old]),
                       .link(directory: "/usr/local/bin"))
        // In a root-owned folder: admin.
        XCTAssertEqual(plan(path: stockPath, writable: [], existing: ["/usr/local/bin/vegabar": old]),
                       .linkAsAdmin(directory: "/usr/local/bin"))
    }

    func testRealFileIsNeverOverwritten() {
        XCTAssertEqual(plan(path: stockPath, writable: ["/usr/local/bin"], existing: ["/usr/local/bin/vegabar": .file]),
                       .blocked(path: "/usr/local/bin/vegabar"))
    }

    func testNormalisesPathEntries() {
        XCTAssertEqual(CLIInstaller.normalize("~/.local/bin/", home: home), "\(home)/.local/bin")
        XCTAssertEqual(CLIInstaller.normalize("/opt/homebrew/bin", home: home), "/opt/homebrew/bin")
    }
}
