import Foundation
import XCTest
import AutolevelerCore
@testable import AutolevelerApp

@MainActor
final class AppModelTests: XCTestCase {
    func testFilesEnqueuedWhileProcessingArePickedUp() async throws {
        let files = try makeFiles(count: 2)
        defer { removeFiles(files) }
        XCTAssertNotEqual(files[0], files[1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[1].path))
        XCTAssertNotEqual(try files[1].resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        let releaseFirst = DispatchSemaphore(value: 0)
        let processed = CallLog()
        let model = AppModel { input, _, _, _ in
            processed.append(input.lastPathComponent)
            if input == files[0] {
                releaseFirst.wait()
            }
            return ProcessingResult(output: input, speechDetected: true)
        }

        model.enqueue([files[0]])
        model.startProcessing()
        await waitUntil { model.items.first?.state == .processing }
        model.enqueue([files[1]])
        XCTAssertEqual(model.items.count, 2)
        releaseFirst.signal()
        await waitUntil { !model.isProcessing }

        XCTAssertEqual(model.items.map(\.state), [.completed, .completed])
        XCTAssertEqual(processed.count, 2)
    }

    func testCancellationLeavesLaterItemsWaiting() async throws {
        let files = try makeFiles(count: 2)
        defer { removeFiles(files) }
        XCTAssertNotEqual(files[0], files[1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[1].path))
        XCTAssertNotEqual(try files[1].resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        let processed = CallLog()
        let model = AppModel { input, _, cancellation, _ in
            processed.append(input.lastPathComponent)
            while true {
                do {
                    try cancellation.check()
                    Thread.sleep(forTimeInterval: 0.01)
                } catch {
                    throw error
                }
            }
        }

        model.enqueue(files)
        XCTAssertEqual(model.items.count, 2)
        model.startProcessing()
        await waitUntil { model.items.first?.state == .processing }
        model.cancelProcessing()
        await waitUntil { !model.isProcessing }

        XCTAssertEqual(model.items.map(\.state), [.cancelled, .waiting])
        XCTAssertEqual(processed.count, 1)
    }

    private func makeFiles(count: Int) throws -> [URL] {
        try (0..<count).map { index in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("app-model-\(UUID().uuidString)-\(index).wav")
            try Data().write(to: url)
            return url
        }
    }

    private func removeFiles(_ files: [URL]) {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for queue state")
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock(); values.append(value); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return values.count
    }
}
