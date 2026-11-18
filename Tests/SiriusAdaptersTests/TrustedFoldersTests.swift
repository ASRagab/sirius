import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

// Fixtures only: a home folder made for each test, never the user's own.
final class TrustedFoldersTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // A folder under the fixture home, created.
    private func folder(_ name: String) throws -> String {
        let url = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func write(_ text: String, to relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reader() -> TrustedFolders {
        let now = now
        // The fixture home lives under the system's temporary folder, so no
        // prefix counts as temporary here; temporary paths are tested on
        // their own.
        return TrustedFolders(home: home.path, now: { now }, modified: { _ in nil }, temporaryPrefixes: [])
    }

    // MARK: Claude

    func testClaudeKeepsOnlyAcceptedFoldersWithTheirLastUse() {
        let json = """
        {"numStartups": 9, "oauthAccount": {"email": "x"},
         "projects": {
           "/a": {"hasTrustDialogAccepted": true, "lastStartTime": 1700000000000, "allowedTools": [], "mcpServers": {}},
           "/b": {"hasTrustDialogAccepted": false},
           "/c": {"allowedTools": []},
           "/d": {"hasTrustDialogAccepted": true, "lastStartTime": 1700000000000, "lastSessionModified": 1700000500000}
         }}
        """
        let folders = TrustedFolders.claude(json: Data(json.utf8))
        XCTAssertEqual(folders, [
            .init(path: "/a", lastUsed: Date(timeIntervalSince1970: 1_700_000_000)),
            .init(path: "/d", lastUsed: Date(timeIntervalSince1970: 1_700_000_500)),
        ])
    }

    func testClaudeWithoutProjectsOrUnreadableIsEmpty() {
        XCTAssertEqual(TrustedFolders.claude(json: Data("{}".utf8)), [])
        XCTAssertEqual(TrustedFolders.claude(json: Data("not json".utf8)), [])
    }

    func testClaudesTranscriptFolderKey() {
        XCTAssertEqual(TrustedFolders.claudeProjectKey("/Users/u/my.project_x"), "-Users-u-my-project-x")
    }

    // MARK: Codex

    func testCodexKeepsOnlyTrustedProjectTablesInFileOrder() {
        let toml = """
        model = "gpt-6"
        [projects."/one"]
        trust_level = "trusted"

        [projects."/two"]
        trust_level = "untrusted"

        [projects.'/three']
        # a comment
        trust_level = 'trusted'  # inline comment

        [sandbox_workspace_write]
        network_access = true
        trust_level = "trusted"

        [projects."/with \\"quote\\""]
        trust_level = "trusted"
        """
        XCTAssertEqual(TrustedFolders.codex(toml: toml).map(\.path), ["/one", "/three", "/with \"quote\""])
    }

    func testCodexWithNoProjectsIsEmpty() {
        XCTAssertEqual(TrustedFolders.codex(toml: "model = \"x\"\n"), [])
    }

    func testMuseKeepsOnlyTrustedProjects() {
        let json = Data("""
        {"schema_version": 1, "projects": {
          "/b": {"decision": "trusted"}, "/a": {"decision": "trusted"}, "/c": {"decision": "untrusted"}}}
        """.utf8)
        XCTAssertEqual(TrustedFolders.muse(json: json).map(\.path), ["/a", "/b"])
        XCTAssertEqual(TrustedFolders.muse(json: Data("{}".utf8)), [])
        XCTAssertEqual(TrustedFolders.muse(json: Data("not json".utf8)), [])
    }

    func testAntigravityKeepsItsTrustedWorkspacesInOrderAndCursorHasNone() {
        let json = Data(#"{"modelProvider": "google", "trustedWorkspaces": ["/b", "/a"]}"#.utf8)
        XCTAssertEqual(TrustedFolders.antigravity(json: json).map(\.path), ["/b", "/a"])
        XCTAssertEqual(TrustedFolders.antigravity(json: Data("{}".utf8)), [])
        XCTAssertEqual(TrustedFolders.antigravity(json: Data("not json".utf8)), [])
        XCTAssertEqual(TrustedFolders(home: "/nowhere").folders(for: .cursor), [])
    }

    // MARK: Filtering and order

    func testTemporaryFoldersAreNeverUsed() throws {
        let reader = TrustedFolders(home: home.path, now: { Date() }, isDirectory: { _ in true })
        XCTAssertEqual(reader.rank([.init(path: "/private/tmp/x"), .init(path: "/Users/u/work")]), ["/Users/u/work"])
        for path in ["/tmp", "/tmp/x", "/private/tmp/x", "/var/folders/ab/T/x", "/private/var/folders/ab"] {
            XCTAssertTrue(TrustedFolders.isTemporary(path), path)
        }
        XCTAssertFalse(TrustedFolders.isTemporary("/tmpfiles/x"))
        XCTAssertFalse(TrustedFolders.isTemporary("/Users/u/tmp"))
    }

    func testMissingHomeRootAndLongUnusedFoldersAreLeftOut() throws {
        let recent = try folder("recent")
        let older = try folder("older")
        let stale = try folder("stale")
        let unknown = try folder("unknown")
        let day: TimeInterval = 24 * 3600
        let ranked = reader().rank([
            .init(path: "/", lastUsed: now),
            .init(path: home.path, lastUsed: now),
            .init(path: home.appendingPathComponent("gone").path, lastUsed: now),
            .init(path: stale, lastUsed: now.addingTimeInterval(-200 * day)),
            .init(path: unknown),
            .init(path: older, lastUsed: now.addingTimeInterval(-10 * day)),
            .init(path: recent, lastUsed: now.addingTimeInterval(-1 * day)),
            .init(path: recent + "/", lastUsed: now),
        ])
        // Newest known first, then the unknown; the duplicate is dropped.
        XCTAssertEqual(ranked, [recent, older, unknown])
    }

    func testFoldersWithoutAKnownUseRankLaterInTheFileFirst() throws {
        let first = try folder("first")
        let second = try folder("second")
        XCTAssertEqual(reader().rank([.init(path: first), .init(path: second)]), [second, first])
    }

    func testEachHarnessGetsOnlyItsOwnFolders() throws {
        let claudeOnly = try folder("claude-only")
        let codexOnly = try folder("codex-only")
        try write("""
        {"projects": {"\(claudeOnly)": {"hasTrustDialogAccepted": true, "lastStartTime": \(now.timeIntervalSince1970 * 1000)}}}
        """, to: ".claude.json")
        try write("""
        [projects."\(codexOnly)"]
        trust_level = "trusted"
        """, to: ".codex/config.toml")
        let trusted = reader()
        XCTAssertEqual(trusted.folders(for: .claudeCode), [claudeOnly])
        XCTAssertEqual(trusted.folders(for: .codex), [codexOnly])
    }

    func testClaudesTranscriptsDateAFolderItsOwnTimesDoNot() throws {
        let dated = try folder("dated")
        let undated = try folder("undated")
        try write("""
        {"projects": {"\(dated)": {"hasTrustDialogAccepted": true},
                      "\(undated)": {"hasTrustDialogAccepted": true}}}
        """, to: ".claude.json")
        let now = now
        let key = TrustedFolders.claudeProjectKey(dated)
        let trusted = TrustedFolders(home: home.path, now: { now }, modified: { $0.hasSuffix("/" + key) ? now : nil },
                                     temporaryPrefixes: [])
        XCTAssertEqual(trusted.folders(for: .claudeCode), [dated, undated])
    }

    func testNoFilesNoFolders() {
        XCTAssertEqual(reader().folders(for: .claudeCode), [])
        XCTAssertEqual(reader().folders(for: .codex), [])
    }
}
