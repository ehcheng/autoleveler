import Foundation
import Darwin

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        if let child, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
    public func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    func launch(_ child: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try child.run(); process = child
    }
    func clear() { lock.lock(); process = nil; lock.unlock() }
    func finish(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try action()
    }
}

struct MediaTools {
    let ffmpeg: URL
    let ffprobe: URL
    init() throws {
        let manager = FileManager.default
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directories: [URL] = []
        if let override = ProcessInfo.processInfo.environment["AUTOLEVELER_TOOLS"] {
            directories.append(URL(fileURLWithPath: override))
        }
        directories += [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers"),
                        executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers"),
                        executable.deletingLastPathComponent(),
                        URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent("dist/media-tools"),
                        URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
        guard let directory = directories.first(where: {
            manager.isExecutableFile(atPath: $0.appendingPathComponent("ffmpeg").path) &&
            manager.isExecutableFile(atPath: $0.appendingPathComponent("ffprobe").path)
        }) else { throw AutolevelerError.message("Media tools are missing. Reinstall Autoleveler or set AUTOLEVELER_TOOLS to a folder containing ffmpeg and ffprobe.") }
        ffmpeg = directory.appendingPathComponent("ffmpeg"); ffprobe = directory.appendingPathComponent("ffprobe")
    }
}

struct ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String], cancellation: CancellationToken,
                    logDirectory: URL, onLine: ((String) -> Void)? = nil) throws -> Data {
        try cancellation.check()
        let log = logDirectory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: log)
        defer { try? errorHandle.close(); try? FileManager.default.removeItem(at: log) }
        let output = Pipe()
        let child = Process()
        child.executableURL = executable; child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output; child.standardError = errorHandle
        try cancellation.launch(child)
        defer { cancellation.clear() }
        var captured = Data(), pending = Data()
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            if let onLine {
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending[..<newline]
                    onLine(String(decoding: line, as: UTF8.self))
                    pending.removeSubrange(...newline)
                }
            } else { captured.append(data) }
        }
        child.waitUntilExit()
        try cancellation.check()
        guard child.terminationStatus == 0 else {
            let diagnostic = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw AutolevelerError.message(String(diagnostic.suffix(3500)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Media processing failed (exit \(child.terminationStatus))." : String(diagnostic.suffix(3500)))
        }
        return captured
    }
}
