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
    init(executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
         bundleURL: URL = Bundle.main.bundleURL,
         overrideDirectory: URL? = ProcessInfo.processInfo.environment["AUTOLEVELER_TOOLS"].map { URL(fileURLWithPath: $0) }) throws {
        let manager = FileManager.default
        let executable = executable.resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let executableApp = contents.deletingLastPathComponent()
        let app: URL?
        if bundleURL.pathExtension == "app" {
            app = bundleURL
        } else if executable.deletingLastPathComponent().lastPathComponent == "MacOS",
                  contents.lastPathComponent == "Contents", executableApp.pathExtension == "app" {
            app = executableApp
        } else {
            app = nil
        }
        let directories: [URL]
        if let app {
            // Packaged apps must use their own tools, even when a development override is set.
            directories = [app.appendingPathComponent("Contents/Helpers")]
        } else if let overrideDirectory {
            directories = [overrideDirectory]
        } else {
            directories = [executable.deletingLastPathComponent(),
                           URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent("dist/media-tools"),
                           URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
        }
        guard let directory = directories.first(where: { directory in
            ["ffmpeg", "ffprobe"].allSatisfy { name in
                let path = directory.appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                return manager.fileExists(atPath: path, isDirectory: &isDirectory) &&
                    !isDirectory.boolValue && manager.isExecutableFile(atPath: path)
            }
        }) else {
            throw AutolevelerError.message(app == nil
                ? "Media tools are missing. Set AUTOLEVELER_TOOLS to a folder containing ffmpeg and ffprobe."
                : "Bundled media tools are missing. Reinstall Autoleveler.")
        }
        ffmpeg = directory.appendingPathComponent("ffmpeg")
        ffprobe = directory.appendingPathComponent("ffprobe")
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
            let diagnostic = (try? diagnosticTail(at: log)) ?? ""
            throw AutolevelerError.message(diagnostic.isEmpty
                ? "Media processing failed (exit \(child.terminationStatus))." : diagnostic)
        }
        return captured
    }

    static func diagnosticTail(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let limit: UInt64 = 16_384
        try handle.seek(toOffset: end > limit ? end - limit : 0)
        let bytes = try handle.read(upToCount: Int(limit)) ?? Data()
        return String(String(decoding: bytes, as: UTF8.self).suffix(3500))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
