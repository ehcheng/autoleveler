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
        make(channelEnergy: [energy], channelSpeech: [speech])
    }

    static func make(channelEnergy: [[EnergyFrame]], channelSpeech: [[SpeechWindow]]) -> GainPlan {
        guard let first = channelEnergy.first, !first.isEmpty else {
            return GainPlan(decibels: [], speechDetected: false)
        }
        precondition(channelEnergy.count == channelSpeech.count && channelEnergy.allSatisfy { $0.count == first.count })
        var voiced = [[Bool]](repeating: [Bool](repeating: false, count: first.count), count: channelEnergy.count)
        var minimumSpeechDB = [Double]()
        for channel in channelEnergy.indices {
            for window in channelSpeech[channel] where window.confidence >= 0.35 {
                let lower = max(0, Int((window.start - 0.1) / hop))
                let upper = min(first.count, Int(ceil((window.end + 0.1) / hop)))
                if upper > lower { for index in lower..<upper { voiced[channel][index] = true } }
            }
            let noise = first.indices.filter { !voiced[channel][$0] && channelEnergy[channel][$0].rms > 0.000_001 }
                .map { 20 * log10(channelEnergy[channel][$0].rms) }.sorted()
            let noiseFloor = noise.isEmpty ? -80 : noise[noise.count / 5]
            minimumSpeechDB.append(max(-75, min(-35, noiseFloor + 6)))
        }
        var desired = [Double](repeating: 0, count: first.count)
        var detected = false
        for index in first.indices {
            var speechDB = -Double.infinity
            for channel in channelEnergy.indices where voiced[channel][index] {
                let energy = channelEnergy[channel]
                let threshold = minimumSpeechDB[channel]
                guard 20 * log10(max(energy[index].rms, 1e-12)) > threshold else { continue }
                let lower = max(0, index - 5), upper = min(first.count - 1, index + 5)
                var power = 0.0, count = 0.0
                for neighbour in lower...upper where voiced[channel][neighbour] && energy[neighbour].rms > pow(10, threshold / 20) {
                    power += energy[neighbour].rms * energy[neighbour].rms; count += 1
                }
                if count > 0 { speechDB = max(speechDB, 10 * log10(max(power / count, 1e-12))) }
            }
            guard speechDB.isFinite else { continue }
            var gain = min(24, max(-18, -20 - speechDB))
            if gain > 0 {
                // One gain curve preserves channel balance. Keep unrelated channels below
                // a safe ceiling rather than boosting loud ambience with quiet speech.
                for channel in channelEnergy.indices where !voiced[channel][index] {
                    let rms = channelEnergy[channel][index].rms
                    if rms > 0 { gain = min(gain, max(0, -12 - 20 * log10(rms))) }
                }
            }
            desired[index] = gain
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
        // Each render block interpolates this gain with the next one. Bound both
        // endpoints against the current and preceding blocks' energy.
        let bounded = smoothed.indices.map { index -> Double in
            var gain = smoothed[index]
            if gain > 0 {
                for frame in max(0, index - 1)...index {
                    for channel in channelEnergy.indices {
                        let energy = channelEnergy[channel][frame]
                        if energy.peak > 0 { gain = min(gain, max(0, 20 * log10(0.98 / energy.peak))) }
                        if !voiced[channel][frame] && energy.rms > 0 {
                            gain = min(gain, max(0, -12 - 20 * log10(energy.rms)))
                        }
                    }
                }
            }
            return gain
        }
        return GainPlan(decibels: bounded, speechDetected: detected)
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
        let analyzers: [SNAudioStreamAnalyzer] = (0..<Int(format.channelCount)).map { _ in
            SNAudioStreamAnalyzer(format: monoFormat)
        }
        let observers = analyzers.map { _ in SpeechObserver() }
        for channel in analyzers.indices {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 48_000)
            request.overlapFactor = 0.5
            try analyzers[channel].add(request, withObserver: observers[channel])
        }
        defer { analyzers.forEach { $0.removeAllRequests() } }
        var channelEnergy = [[EnergyFrame]](repeating: [], count: analyzers.count)
        while file.framePosition < file.length {
            try cancellation.check()
            let position = file.framePosition
            try file.read(into: buffer, frameCount: hop)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData, let monoData = mono.floatChannelData else { break }
            mono.frameLength = buffer.frameLength
            for channel in analyzers.indices {
                var power = 0.0, peak = 0.0
                for sample in 0..<count {
                    let value = Double(channels[channel][sample])
                    guard value.isFinite else { throw AutolevelerError.message("Input contains invalid audio samples.") }
                    power += value * value; peak = max(peak, abs(value))
                }
                channelEnergy[channel].append(EnergyFrame(rms: sqrt(power / Double(count)), peak: peak))
                monoData[0].update(from: channels[channel], count: count)
                analyzers[channel].analyze(mono, atAudioFramePosition: position)
            }
            progress(Double(file.framePosition) / Double(max(1, file.length)))
        }
        analyzers.forEach { $0.completeAnalysis() }
        for observer in observers {
            while observer.completed.wait(timeout: .now() + 0.1) == .timedOut { try cancellation.check() }
        }
        try cancellation.check()
        return try GainPlan.make(channelEnergy: channelEnergy, channelSpeech: observers.map { try $0.result() })
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
