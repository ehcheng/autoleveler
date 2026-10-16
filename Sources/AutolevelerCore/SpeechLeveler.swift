import Foundation
import AVFoundation
import SoundAnalysis

struct EnergyFrame: Sendable {
    let rms: Double
    let peak: Double
}
struct SpeechWindow: Sendable {
    let start: Double
    let end: Double
    let confidence: Double
}

private final class SpeechObserver: NSObject, SNResultsObserving {
    private let lock = NSLock()
    private var storage: [SpeechWindow] = []
    private var failure: Error?
    let completed = DispatchSemaphore(value: 0)
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let speech = result.classification(forIdentifier: "speech") else { return }
        let start = result.timeRange.start.seconds
        let window = SpeechWindow(start: start, end: start + result.timeRange.duration.seconds, confidence: speech.confidence)
        lock.lock(); storage.append(window); lock.unlock()
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock(); failure = error; lock.unlock(); completed.signal()
    }
    func requestDidComplete(_ request: SNRequest) { completed.signal() }
    func result() throws -> [SpeechWindow] {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        return storage
    }
}

struct GainPlan {
    let decibels: [Double]
    let speechDetected: Bool
    static let hop = 0.05

    static func make(energy: [EnergyFrame], speech: [SpeechWindow]) -> GainPlan {
        guard !energy.isEmpty else { return GainPlan(decibels: [], speechDetected: false) }
        var voiced = [Bool](repeating: false, count: energy.count)
        for window in speech where window.confidence >= 0.35 {
            let lower = max(0, Int((window.start - 0.1) / hop))
            let upper = min(energy.count, Int(ceil((window.end + 0.1) / hop)))
            if upper > lower { for index in lower..<upper { voiced[index] = true } }
        }
        let noise = energy.indices.filter { !voiced[$0] && energy[$0].rms > 0.000_001 }
            .map { 20 * log10(energy[$0].rms) }.sorted()
        let noiseFloor = noise.isEmpty ? -80 : noise[noise.count / 5]
        let minimumSpeechDB = max(-75, min(-35, noiseFloor + 6))
        var desired = [Double](repeating: 0, count: energy.count)
        var detected = false
        for index in energy.indices where voiced[index] && 20 * log10(max(energy[index].rms, 1e-12)) > minimumSpeechDB {
            let lower = max(0, index - 5), upper = min(energy.count - 1, index + 5)
            var power = 0.0, count = 0.0
            for neighbour in lower...upper where voiced[neighbour] && energy[neighbour].rms > pow(10, minimumSpeechDB / 20) {
                power += energy[neighbour].rms * energy[neighbour].rms; count += 1
            }
            guard count > 0 else { continue }
            let speechDB = 10 * log10(max(power / count, 1e-12))
            desired[index] = min(24, max(-18, -20 - speechDB))
            detected = true
        }
        // Smooth in dB; return to unity through pauses instead of raising the noise floor.
        let smoothed = desired.indices.map { index -> Double in
            let lower = max(0, index - 3), upper = min(desired.count - 1, index + 3)
            var sum = 0.0, weights = 0.0
            for neighbour in lower...upper {
                let weight = Double(4 - abs(index - neighbour))
                sum += desired[neighbour] * weight; weights += weight
            }
            return sum / weights
        }
        return GainPlan(decibels: smoothed, speechDetected: detected)
    }
}

struct SpeechLeveler {
    static func analyze(_ url: URL, cancellation: CancellationToken,
                        progress: (Double) -> Void) throws -> GainPlan {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0 else { throw AutolevelerError.message("The audio track is empty.") }
        let format = file.processingFormat
        let hop = AVAudioFrameCount(format.sampleRate * GainPlan.hop)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: hop),
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: hop) else {
            throw AutolevelerError.message("Could not allocate an audio buffer.")
        }
        let analyzer = SNAudioStreamAnalyzer(format: monoFormat)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        let observer = SpeechObserver()
        try analyzer.add(request, withObserver: observer)
        defer { analyzer.removeAllRequests() }
        var energy: [EnergyFrame] = []
        while file.framePosition < file.length {
            try cancellation.check()
            let position = file.framePosition
            try file.read(into: buffer, frameCount: hop)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData, let monoData = mono.floatChannelData else { break }
            var largestPower = 0.0, peak = 0.0, selectedChannel = 0
            for channel in 0..<Int(format.channelCount) {
                var power = 0.0
                for sample in 0..<count {
                    let value = Double(channels[channel][sample])
                    guard value.isFinite else { throw AutolevelerError.message("Input contains invalid audio samples.") }
                    power += value * value; peak = max(peak, abs(value))
                }
                if power > largestPower { largestPower = power; selectedChannel = channel }
            }
            energy.append(EnergyFrame(rms: sqrt(largestPower / Double(count)), peak: peak))
            mono.frameLength = buffer.frameLength
            monoData[0].update(from: channels[selectedChannel], count: count)
            analyzer.analyze(mono, atAudioFramePosition: position)
            progress(Double(file.framePosition) / Double(max(1, file.length)))
        }
        analyzer.completeAnalysis()
        while observer.completed.wait(timeout: .now() + 0.1) == .timedOut { try cancellation.check() }
        try cancellation.check()
        return GainPlan.make(energy: energy, speech: try observer.result())
    }

    static func render(_ source: URL, to destination: URL, plan: GainPlan,
                       cancellation: CancellationToken, progress: (Double) -> Void) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        let output = try AVAudioFile(forWriting: destination, settings: format.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let hop = AVAudioFrameCount(format.sampleRate * GainPlan.hop)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: hop) else {
            throw AutolevelerError.message("Could not allocate an audio buffer.")
        }
        var index = 0, previousDB = plan.decibels.first ?? 0
        while input.framePosition < input.length {
            try cancellation.check()
            try input.read(into: buffer, frameCount: hop)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { break }
            let nextDB = index + 1 < plan.decibels.count ? plan.decibels[index + 1] : (plan.decibels.last ?? 0)
            for sample in 0..<count {
                let blend = Double(sample) / Double(count)
                let gain = Float(pow(10, (previousDB + (nextDB - previousDB) * blend) / 20))
                for channel in 0..<Int(format.channelCount) { channels[channel][sample] *= gain }
            }
            try output.write(from: buffer)
            previousDB = nextDB; index += 1
            progress(Double(input.framePosition) / Double(max(1, input.length)))
        }
    }
}
