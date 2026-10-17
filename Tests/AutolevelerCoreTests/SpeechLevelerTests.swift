import AVFoundation
import XCTest
@testable import AutolevelerCore

final class SpeechLevelerTests: XCTestCase {
    func testOfflineAnalyzerFindsQuietRightChannelSpeechBesideLouderLeftTone() throws {
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/fixtures/speech.aiff")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Optional speech fixture is unavailable")
        }
        let input = try AVAudioFile(forReading: fixture, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        XCTAssertEqual(format.channelCount, 1)
        let chunk: AVAudioFrameCount = 4096
        let read = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk))
        var sourcePower = 0.0, sourceCount = 0
        while input.framePosition < input.length {
            try input.read(into: read)
            let samples = try XCTUnwrap(read.floatChannelData?[0])
            for index in 0..<Int(read.frameLength) {
                sourcePower += Double(samples[index] * samples[index])
            }
            sourceCount += Int(read.frameLength)
        }
        XCTAssertGreaterThan(sourcePower, 0)
        let scale = pow(10, -34.0 / 20) / sqrt(sourcePower / Double(sourceCount))
        input.framePosition = 0

        let stereoFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: chunk))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoleveler-stereo-speech-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: destination) }
        let writer = try AVAudioFile(forWriting: destination, settings: stereoFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        var position = 0
        let toneAmplitude = sqrt(2) * pow(10, -22.0 / 20)
        while input.framePosition < input.length {
            try input.read(into: read)
            output.frameLength = read.frameLength
            let source = try XCTUnwrap(read.floatChannelData?[0])
            let left = try XCTUnwrap(output.floatChannelData?[0])
            let right = try XCTUnwrap(output.floatChannelData?[1])
            for index in 0..<Int(read.frameLength) {
                left[index] = Float(toneAmplitude * sin(2 * .pi * 220 * Double(position) / format.sampleRate))
                right[index] = Float(Double(source[index]) * scale)
                position += 1
            }
            try writer.write(from: output)
        }
        let plan = try SpeechLeveler.analyze(destination, cancellation: CancellationToken()) { _ in }
        XCTAssertTrue(plan.speechDetected)
        XCTAssertGreaterThan(plan.decibels.max() ?? 0, 2)
        XCTAssertLessThanOrEqual(plan.decibels.max() ?? .infinity, 10.1)
    }
}
