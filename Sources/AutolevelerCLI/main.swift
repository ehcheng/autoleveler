import Foundation
import AutolevelerCore
import Darwin

func writeError(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
final class ProgressPrinter: @unchecked Sendable {
    let input: URL
    private let lock = NSLock()
    private var lastStage = ""
    init(input: URL) { self.input = input }
    func display(_ progress: ProcessingProgress) {
        lock.lock(); defer { lock.unlock() }
        if isatty(STDERR_FILENO) != 0 {
            writeError("\r\u{001B}[K\(input.lastPathComponent): \(progress.message) · \(Int(progress.fraction * 100))%")
        } else if progress.message != lastStage {
            writeError("\(input.lastPathComponent): \(progress.message)\n")
            lastStage = progress.message
        }
    }
}
let usage = """
Autoleveler — speech-aware audio leveling, entirely on your Mac.

Usage: autoleveler [options] FILE [FILE ...]

  --format aac|mp3|pcm    Audio codec (default: aac)
  --bitrate KBPS         AAC/MP3 bitrate, 32–320 (default: 192)
  --audio                Export audio only
  --video                Copy video and replace its audio
  -o, --output-dir DIR   Destination (default: each input's folder)
  --                     End options; allow filenames starting with '-'
  -h, --help             Show this help
  --version              Show version

Outputs use a '-leveled' suffix and never overwrite an existing file.
AAC audio is .m4a, MP3 is .mp3, PCM is 24-bit .wav. Video uses a
compatible source container, MOV, or MKV; video is never re-encoded.
Ctrl-C cancels processing and removes temporary files.
"""

var options = ProcessingOptions()
var inputs: [URL] = []
var arguments = Array(CommandLine.arguments.dropFirst())
var positionalOnly = false
func takeValue(_ option: String) throws -> String {
    guard !arguments.isEmpty else { throw AutolevelerError.message("Missing value for \(option).") }
    return arguments.removeFirst()
}
do {
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        if positionalOnly { inputs.append(URL(fileURLWithPath: argument)); continue }
        switch argument {
        case "--": positionalOnly = true
        case "--help", "-h": print(usage); exit(0)
        case "--version": print("Autoleveler \(AppVersion.display)"); exit(0)
        case "--format":
            let value = try takeValue(argument)
            guard let codec = AudioCodec(rawValue: value) else { throw AutolevelerError.message("Unknown format '\(value)'; use aac, mp3, or pcm.") }
            options.codec = codec
        case "--bitrate":
            guard let value = Int(try takeValue(argument)), (32...320).contains(value) else { throw AutolevelerError.message("Bitrate must be between 32 and 320 kb/s.") }
            options.bitrate = value
        case "--audio": options.outputMode = .audio
        case "--video": options.outputMode = .video
        case "--output-dir", "-o": options.outputDirectory = URL(fileURLWithPath: try takeValue(argument), isDirectory: true)
        default:
            if argument.hasPrefix("-") { throw AutolevelerError.message("Unknown option '\(argument)'. Use --help for usage.") }
            inputs.append(URL(fileURLWithPath: argument))
        }
    }
    guard !inputs.isEmpty else { print(usage); exit(2) }
    let cancellation = CancellationToken()
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    interrupt.setEventHandler { cancellation.cancel() }; interrupt.resume()
    terminate.setEventHandler { cancellation.cancel() }; terminate.resume()
    let processor = try MediaProcessor()
    var failures = 0
    for input in inputs {
        do {
            let printer = ProgressPrinter(input: input)
            let result = try processor.process(input: input, options: options, cancellation: cancellation) { progress in
                printer.display(progress)
            }
            if isatty(STDERR_FILENO) != 0 { writeError("\n") }
            print(result.output.path)
            if !result.speechDetected { writeError("No confident speech detected; audio retained without gain boost.\n") }
        } catch is CancellationError {
            writeError("\nCancelled. Temporary files removed.\n"); exit(130)
        } catch {
            failures += 1; writeError("\n\(input.lastPathComponent): \(error.localizedDescription)\n")
        }
    }
    withExtendedLifetime((interrupt, terminate)) {}
    exit(failures == 0 ? 0 : 1)
} catch {
    writeError("autoleveler: \(error.localizedDescription)\n"); exit(2)
}
