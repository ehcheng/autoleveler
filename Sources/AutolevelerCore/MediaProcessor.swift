import Foundation
import Darwin

struct MediaProbe: Decodable {
    struct Stream: Decodable {
        let index: Int
        let codec_type: String?
        let codec_name: String?
        let start_time: String?
        let channels: Int?
        var disposition: [String: Int]? = nil
    }
    struct Format: Decodable {
        let duration: String?
        let start_time: String?
    }
    let streams: [Stream]
    let format: Format?
}

public final class MediaProcessor: @unchecked Sendable {
    private let tools: MediaTools
    public init() throws { tools = try MediaTools(); Workspace.recover() }

    public func process(input: URL, options: ProcessingOptions, cancellation: CancellationToken,
                        progress: @escaping @Sendable (ProcessingProgress) -> Void) throws -> ProcessingResult {
        let updates = ProgressReporter(progress)
        try cancellation.check()
        let manager = FileManager.default
        let source = input.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard source.isFileURL, manager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AutolevelerError.message("Input must be an existing local audio or video file.")
        }
        guard (32...320).contains(options.bitrate) else { throw AutolevelerError.message("Bitrate must be between 32 and 320 kb/s.") }
        let destination = (options.outputDirectory ?? source.deletingLastPathComponent()).standardizedFileURL
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let workspace = try Workspace()
        let localProtocols = ["-protocol_whitelist", "file,pipe,crypto,data"]
        updates.send(ProcessingProgress(fraction: 0, message: "Reading media"))
        let data = try ProcessRunner.run(tools.ffprobe,
            ["-v", "error"] + localProtocols + ["-show_streams", "-show_format", "-of", "json", source.path],
            cancellation: cancellation, logDirectory: workspace.directory)
        let media = try JSONDecoder().decode(MediaProbe.self, from: data)
        let audio = media.streams.filter { $0.codec_type == "audio" }
        let hasVideo = media.streams.contains { $0.codec_type == "video" && ($0.disposition?["attached_pic"] ?? 0) == 0 }
        guard !audio.isEmpty else { throw AutolevelerError.message("This file has no audio track to level.") }
        guard options.outputMode != .video || hasVideo else { throw AutolevelerError.message("Video output requires a video input. Choose Audio only or Match input.") }
        let keepVideo = options.outputMode == .video || (options.outputMode == .automatic && hasVideo)
        let duration = Double(media.format?.duration ?? "") ?? 0
        let preferredAudio = audio.first(where: { $0.disposition?["default"] == 1 }) ?? audio[0]
        let tracks = keepVideo ? audio : [preferredAudio]
        if options.codec == .mp3, tracks.contains(where: { ($0.channels ?? 2) > 2 }) {
            throw AutolevelerError.message("MP3 supports at most two channels. Choose AAC or PCM to preserve this file's channels.")
        }
        var leveled: [URL] = []
        var detected = false
        for (ordinal, track) in tracks.enumerated() {
            let base = 0.02 + 0.76 * Double(ordinal) / Double(tracks.count)
            let share = 0.76 / Double(tracks.count)
            let suffix = tracks.count > 1 ? " · track \(ordinal + 1)/\(tracks.count)" : ""
            let decoded = workspace.directory.appendingPathComponent("decoded-\(ordinal).caf")
            try ffmpeg(["-v", "error"] + localProtocols + ["-i", source.path, "-map", "0:\(track.index)",
                "-vn", "-sn", "-dn", "-ar", "48000", "-c:a", "pcm_f32le", decoded.path],
                cancellation: cancellation, workspace: workspace, duration: duration) { fraction in
                    updates.send(ProcessingProgress(fraction: base + share * 0.22 * fraction, message: "Decoding audio" + suffix))
                }
            let plan = try SpeechLeveler.analyze(decoded, cancellation: cancellation) { fraction in
                updates.send(ProcessingProgress(fraction: base + share * (0.22 + 0.48 * fraction), message: "Listening for speech" + suffix))
            }
            detected = detected || plan.speechDetected
            let processed = workspace.directory.appendingPathComponent("leveled-\(ordinal).caf")
            try SpeechLeveler.render(decoded, to: processed, plan: plan, cancellation: cancellation) { fraction in
                updates.send(ProcessingProgress(fraction: base + share * (0.7 + 0.3 * fraction), message: "Balancing dialogue" + suffix))
            }
            try manager.removeItem(at: decoded)
            leveled.append(processed)
        }
        let outputExtension = Self.outputExtension(source: source, codec: options.codec, keepVideo: keepVideo, streams: media.streams)
        let partial = try workspace.stage(in: destination, extension: outputExtension)
        var arguments = ["-v", "error"] + localProtocols + ["-i", source.path]
        let formatStart = Double(media.format?.start_time ?? "") ?? 0
        for (index, url) in leveled.enumerated() {
            let offset = keepVideo ? (Double(tracks[index].start_time ?? "") ?? formatStart) - formatStart : 0
            arguments += ["-itsoffset", String(offset), "-i", url.path]
        }
        if keepVideo {
            arguments += ["-map", "0:v?", "-map", "0:s?"]
            if outputExtension == "mkv" { arguments += ["-map", "0:t?"] }
        }
        for index in leveled.indices { arguments += ["-map", "\(index + 1):a:0"] }
        arguments += ["-map_metadata", "0", "-map_chapters", "0", "-c", "copy"]
        for index in leveled.indices {
            arguments += ["-map_metadata:s:a:\(index)", "0:s:\(tracks[index].index)"]
            let disposition = (tracks[index].disposition ?? [:]).filter { $0.value != 0 }.keys.sorted().joined(separator: "+")
            arguments += ["-disposition:a:\(index)", disposition.isEmpty ? "0" : disposition]
        }
        // Oversample before limiting; leave codec headroom and compensate limiter latency.
        let audioOffset = max(0, (Double(preferredAudio.start_time ?? "") ?? formatStart) - formatStart)
        let leadingSilence = !keepVideo && audioOffset > 0 ? "adelay=\(Int((audioOffset * 48000).rounded()))S:all=1," : ""
        let filter = leadingSilence + "acompressor=threshold=0.25:ratio=2:attack=15:release=180:makeup=1," +
            "aresample=192000,alimiter=limit=0.794328:attack=5:release=80:level=false:latency=true,aresample=48000"
        switch options.codec {
        case .aac: arguments += ["-c:a", "aac", "-b:a", "\(options.bitrate)k"]
        case .mp3:
            arguments += ["-c:a", "libmp3lame", "-b:a", "\(options.bitrate)k"]
        case .pcm:
            arguments += ["-c:a", "pcm_s24le"]
            if !keepVideo { arguments += ["-rf64", "auto"] }
        }
        arguments += ["-filter:a", filter]
        if ["mp4", "mov", "m4a"].contains(outputExtension) { arguments += ["-movflags", "+faststart"] }
        arguments.append(partial.path)
        try ffmpeg(arguments, cancellation: cancellation, workspace: workspace, duration: duration) { fraction in
            updates.send(ProcessingProgress(fraction: 0.78 + fraction * 0.21, message: keepVideo ? "Saving · copying video" : "Saving audio"))
        }
        var output: URL!
        try cancellation.finish {
            let stem = source.deletingPathExtension().lastPathComponent + "-leveled"
            var number = 1
            while true {
                let name = stem + (number == 1 ? "" : "-\(number)") + "." + outputExtension
                let candidate = destination.appendingPathComponent(name)
                if renamex_np(partial.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { output = candidate; break }
                if errno == EEXIST { number += 1; continue }
                throw AutolevelerError.message("Could not save the output: \(String(cString: strerror(errno))).")
            }
            try? manager.removeItem(at: partial)
        }
        updates.send(ProcessingProgress(fraction: 1, message: "Done"))
        return ProcessingResult(output: output, speechDetected: detected)
    }

    private func ffmpeg(_ arguments: [String], cancellation: CancellationToken, workspace: Workspace,
                        duration: Double, progress: @escaping (Double) -> Void) throws {
        _ = try ProcessRunner.run(tools.ffmpeg, ["-nostdin", "-n", "-progress", "pipe:1", "-nostats"] + arguments,
                                 cancellation: cancellation, logDirectory: workspace.directory) { line in
            if line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)), duration > 0 {
                progress(min(1, max(0, micros / 1_000_000 / duration)))
            }
        }
    }

    static func outputExtension(source: URL, codec: AudioCodec, keepVideo: Bool, streams: [MediaProbe.Stream]) -> String {
        guard keepVideo else { return codec.fileExtension }
        let original = source.pathExtension.lowercased()
        if codec == .aac, ["mp4", "m4v", "mov"].contains(original) { return original == "m4v" ? "mp4" : original }
        let movCodecs = ["h264", "hevc", "prores", "mjpeg", "qtrle", "rawvideo"]
        if codec == .pcm, ["mp4", "m4v", "mov"].contains(original),
           streams.filter({ $0.codec_type == "video" }).allSatisfy({ movCodecs.contains($0.codec_name ?? "") }) { return "mov" }
        return "mkv"
    }
}

private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime = 0.0
    private var lastMessage = ""
    private let callback: @Sendable (ProcessingProgress) -> Void
    init(_ callback: @escaping @Sendable (ProcessingProgress) -> Void) { self.callback = callback }
    func send(_ progress: ProcessingProgress) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let emit = progress.message != lastMessage || now - lastTime >= 0.1 || progress.fraction >= 1
        if emit { lastMessage = progress.message; lastTime = now }
        lock.unlock()
        if emit { callback(progress) }
    }
}
