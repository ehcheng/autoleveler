import XCTest
@testable import AutolevelerCore

final class WorkspaceTests: XCTestCase {
    func testRecoveryLeavesActiveWorkspaceAndCleanupRemovesIt() throws {
        var workspace: Workspace? = try Workspace()
        let path = try XCTUnwrap(workspace?.directory)
        Workspace.recover()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        workspace = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testAbandonedWorkspaceAndPartialAreRecovered() throws {
        let manager = FileManager.default
        let folder = Workspace.root.appendingPathComponent("job-" + UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let name = ".autoleveler-" + folder.lastPathComponent + ".partial.wav"
        let partial = manager.temporaryDirectory.appendingPathComponent(name)
        defer { try? manager.removeItem(at: partial) }
        try Data("partial output".utf8).write(to: partial)
        try Data().write(to: folder.appendingPathComponent("lock"))
        try JSONEncoder().encode(["partial": partial.path, "name": name])
            .write(to: folder.appendingPathComponent("manifest.json"))
        Workspace.recover()
        XCTAssertFalse(manager.fileExists(atPath: folder.path))
        XCTAssertFalse(manager.fileExists(atPath: partial.path))
    }
}
