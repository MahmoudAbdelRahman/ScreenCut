@preconcurrency import AVFoundation
import Foundation

enum ExportQuality: String, CaseIterable, Identifiable {
    case high, balanced, small

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "High"
        case .balanced: return "Balanced (recommended)"
        case .small: return "Small"
        }
    }

    /// Bits per pixel per frame for H.264. Screen content needs far less than camera video.
    var bitsPerPixel: Double {
        switch self {
        case .high: return 0.10
        case .balanced: return 0.06
        case .small: return 0.035
        }
    }
}

struct VideoExportSettings {
    var hevc = false
    var quality = ExportQuality.balanced

    func videoBitrate(size: CGSize, fps: Int) -> Int {
        let bpp = quality.bitsPerPixel * (hevc ? 0.6 : 1)
        return max(500_000, Int(size.width * size.height * Double(fps) * bpp))
    }

    static let audioBitrate = 160_000

    func estimatedBytes(size: CGSize, fps: Int, duration: Double) -> Double {
        Double(videoBitrate(size: size, fps: fps) + Self.audioBitrate) * duration / 8
    }
}

/// Renders a built timeline with AVAssetReader -> AVAssetWriter so the bitrate can be controlled
/// (AVAssetExportSession presets cannot).
enum VideoWriter {
    static func export(_ built: BuiltTimeline, to url: URL, settings: VideoExportSettings, fps: Int,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = built.composition
        let reader = try AVAssetReader(asset: asset)
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let aTracks = try await asset.loadTracks(withMediaType: .audio)

        let vOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: vTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = built.videoComposition
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)

        var aOut: AVAssetReaderAudioMixOutput?
        if !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            o.audioMix = built.audioMix
            o.audioTimePitchAlgorithm = .spectral
            reader.add(o)
            aOut = o
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let size = built.videoComposition.renderSize
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.videoBitrate(size: size, fps: fps),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
        ]
        if !settings.hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: VideoExportSettings.audioBitrate,
            ])
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            aIn = i
        }

        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "ScreenCut", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "Could not read the timeline"])
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ScreenCut", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "Could not write the file"])
        }
        writer.startSession(atSourceTime: .zero)

        let duration = max(built.duration, 0.001)
        async let videoDone: Void = pump(vOut, into: vIn, label: "video") { t in
            progress(min(1, t.seconds / duration))
        }
        if let aOut, let aIn {
            async let audioDone: Void = pump(aOut, into: aIn, label: "audio", onSample: nil)
            _ = await (videoDone, audioDone)
        } else {
            await videoDone
        }

        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw writer.error ?? reader.error ?? NSError(domain: "ScreenCut", code: 4,
                                                          userInfo: [NSLocalizedDescriptionKey: "Export failed"])
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "ScreenCut", code: 5,
                                          userInfo: [NSLocalizedDescriptionKey: "Export did not complete"])
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ f: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            f()
        }
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
                             onSample: (@Sendable (CMTime) -> Void)?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = Once()
            let queue = DispatchQueue(label: "screencut.export.\(label)")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        once.run { input.markAsFinished(); cont.resume() }
                        return
                    }
                    onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
                    if !input.append(sample) {
                        once.run { input.markAsFinished(); cont.resume() }
                        return
                    }
                }
            }
        }
    }
}
