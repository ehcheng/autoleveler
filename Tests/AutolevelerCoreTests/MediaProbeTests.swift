import XCTest
@testable import AutolevelerCore

final class MediaProbeTests: XCTestCase {
    private func stream(_ index: Int, _ type: String, _ codec: String) -> MediaProbe.Stream {
        MediaProbe.Stream(index: index, codec_type: type, codec_name: codec, start_time: "0", channels: 2)
    }

    func testAudioOutputExtensions() {
        let source = URL(fileURLWithPath: "/tmp/input.mp4")
        let streams = [stream(0, "video", "h264"), stream(1, "audio", "aac")]
        XCTAssertEqual(MediaProcessor.outputExtension(source: source, codec: .aac, keepVideo: false, streams: streams), "m4a")
        XCTAssertEqual(MediaProcessor.outputExtension(source: source, codec: .mp3, keepVideo: false, streams: streams), "mp3")
        XCTAssertEqual(MediaProcessor.outputExtension(source: source, codec: .pcm, keepVideo: false, streams: streams), "wav")
    }

    func testVideoOutputKeepsCompatibleContainerWhenPossible() {
        let source = URL(fileURLWithPath: "/tmp/input.mp4")
        let streams = [stream(0, "video", "h264"), stream(1, "audio", "aac")]
        XCTAssertEqual(MediaProcessor.outputExtension(source: source, codec: .aac, keepVideo: true, streams: streams), "mp4")
        XCTAssertEqual(MediaProcessor.outputExtension(source: source, codec: .pcm, keepVideo: true, streams: streams), "mov")
    }

    func testVideoOutputFallsBackToMatroskaForIncompatibleAudio() {
        let source = URL(fileURLWithPath: "/tmp/input.mp4")
        let streams = [stream(0, "video", "h264"), stream(1, "audio", "aac")]
        XCTAssertEqual(MediaProcessor.outputExtension(source: source, codec: .mp3, keepVideo: true, streams: streams), "mkv")
    }
}
