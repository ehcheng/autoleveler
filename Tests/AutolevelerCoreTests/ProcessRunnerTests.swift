import XCTest
@testable import AutolevelerCore

final class ProcessRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func tools(at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["ffmpeg", "ffprobe"] {
            let file = folder.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    func testPackagedToolsIgnoreDevelopmentOverride() throws {
        let app = directory.appendingPathComponent("Test.app")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        let development = directory.appendingPathComponent("development")
        try tools(at: helpers)
        try tools(at: development)
        let resolved = try MediaTools(executable: app.appendingPathComponent("Contents/MacOS/autoleveler"),
                                      bundleURL: directory, overrideDirectory: development)
        XCTAssertEqual(resolved.ffmpeg, helpers.appendingPathComponent("ffmpeg"))
    }

    func testIncompleteBundleCannotUseDevelopmentTools() throws {
        let app = directory.appendingPathComponent("Test.app")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        let development = directory.appendingPathComponent("development")
        try tools(at: helpers)
        try tools(at: development)
        try FileManager.default.removeItem(at: helpers.appendingPathComponent("ffprobe"))
        XCTAssertThrowsError(try MediaTools(executable: app.appendingPathComponent("Contents/MacOS/autoleveler"),
                                           bundleURL: directory, overrideDirectory: development)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Reinstall"))
        }
    }

    func testBundleURLAlsoRequiresBundledTools() throws {
        let development = directory.appendingPathComponent("development")
        try tools(at: development)
        XCTAssertThrowsError(try MediaTools(executable: directory.appendingPathComponent("cli"),
                                           bundleURL: directory.appendingPathComponent("Missing.app"),
                                           overrideDirectory: development))
    }

    func testDevelopmentOverrideRequiresCompletePair() throws {
        let development = directory.appendingPathComponent("development")
        try tools(at: development)
        let resolved = try MediaTools(executable: directory.appendingPathComponent("cli"),
                                      bundleURL: directory, overrideDirectory: development)
        XCTAssertEqual(resolved.ffprobe, development.appendingPathComponent("ffprobe"))
        try FileManager.default.removeItem(at: development.appendingPathComponent("ffprobe"))
        XCTAssertThrowsError(try MediaTools(executable: directory.appendingPathComponent("cli"),
                                           bundleURL: directory, overrideDirectory: development))
    }

    func testDiagnosticReadsOnlyTailOfLargeLog() throws {
        let log = directory.appendingPathComponent("large.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: 100 * 1024 * 1024)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(repeating: "x", count: 4000) + "final diagnostic\n").utf8))
        try handle.close()
        let diagnostic = try ProcessRunner.diagnosticTail(at: log)
        XCTAssertLessThanOrEqual(diagnostic.count, 3500)
        XCTAssertTrue(diagnostic.hasSuffix("final diagnostic"))
    }

    func testProcessFailureReportsDiagnosticAndCleansLog() throws {
        XCTAssertThrowsError(try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "printf 'failure sentinel' >&2; exit 7"], cancellation: CancellationToken(),
            logDirectory: directory)) { error in
            XCTAssertEqual(error.localizedDescription, "failure sentinel")
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
