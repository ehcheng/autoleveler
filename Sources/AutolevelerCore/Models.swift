import Foundation

public enum AudioCodec: String, CaseIterable, Identifiable, Sendable {
    case aac, mp3, pcm
    public var id: String { rawValue }
    public var label: String {
        switch self { case .aac: return "AAC"; case .mp3: return "MP3"; case .pcm: return "PCM · 24-bit" }
    }
    public var fileExtension: String {
        switch self { case .aac: return "m4a"; case .mp3: return "mp3"; case .pcm: return "wav" }
    }
}

public enum OutputMode: String, CaseIterable, Identifiable, Sendable {
    case automatic, audio, video
    public var id: String { rawValue }
    public var label: String {
        switch self { case .automatic: return "Match input"; case .audio: return "Audio only"; case .video: return "Video + audio" }
    }
}

public struct ProcessingOptions: Sendable {
    public var codec: AudioCodec
    public var bitrate: Int
    public var outputMode: OutputMode
    public var outputDirectory: URL?
    public init(codec: AudioCodec = .aac, bitrate: Int = 192, outputMode: OutputMode = .automatic, outputDirectory: URL? = nil) {
        self.codec = codec; self.bitrate = bitrate; self.outputMode = outputMode; self.outputDirectory = outputDirectory
    }
}

public struct ProcessingProgress: Sendable {
    public let fraction: Double
    public let message: String
    public init(fraction: Double, message: String) { self.fraction = fraction; self.message = message }
}

public struct ProcessingResult: Sendable {
    public let output: URL
    public let speechDetected: Bool
    public init(output: URL, speechDetected: Bool) {
        self.output = output
        self.speechDetected = speechDetected
    }
}

public enum AutolevelerError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
