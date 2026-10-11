@preconcurrency import AVFoundation
import CoreImage

func cm(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 6000) }

struct SourceInfo {
    let asset: AVURLAsset
    let video: AVAssetTrack?
    let audio: [AVAssetTrack]
    let naturalSize: CGSize
    let orientation: CGImagePropertyOrientation
    let duration: Double

    var orientedSize: CGSize {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return CGSize(width: naturalSize.height, height: naturalSize.width)
        default:
            return naturalSize
        }
    }
}

@MainActor
final class SourceCache {
    private var infos: [String: SourceInfo] = [:]

    func info(for path: String) async throws -> SourceInfo {
        if let i = infos[path] { return i }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path),
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var size = CGSize.zero
        var orientation = CGImagePropertyOrientation.up
        if let video {
            let (s, t) = try await video.load(.naturalSize, .preferredTransform)
            size = s
            let angle = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
            switch angle {
            case 90: orientation = .right
            case -90: orientation = .left
            case 180, -180: orientation = .down
            default: orientation = .up
            }
        }
        let info = SourceInfo(asset: asset, video: video, audio: audio, naturalSize: size,
                              orientation: orientation, duration: duration)
        infos[path] = info
        return info
    }
}

struct BuiltTimeline {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let duration: Double
}

enum CompositionBuilder {
    @MainActor
    static func build(_ project: Project, cache: SourceCache) async throws -> BuiltTimeline? {
        let (placed, _) = TimelineLayout.layout(project.segments)
        guard !placed.isEmpty else { return nil }

        let comp = AVMutableComposition()
        let vTracks = (0..<2).compactMap { _ in
            comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        var aTracks: [[AVMutableCompositionTrack]] = [[], []]
        var params: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        var items: [RenderItem] = []
        var firstSize = CGSize.zero

        for (i, p) in placed.enumerated() {
            let seg = p.segment
            let info = try await cache.info(for: seg.sourcePath)
            let src = CMTimeRange(start: cm(seg.sourceStart), end: cm(min(seg.sourceEnd, info.duration)))
            let at = cm(p.start)
            let nextOverlap = i + 1 < placed.count ? placed[i + 1].overlapIn : 0

            if let v = info.video {
                try insert(v, range: src, into: vTracks[p.slot], at: at, speed: seg.speed)
                if i == 0 {
                    let o = info.orientedSize
                    firstSize = CGSize(width: o.width * seg.crop.w, height: o.height * seg.crop.h)
                }
            }

            for (k, a) in info.audio.enumerated() {
                while aTracks[p.slot].count <= k {
                    guard let t = comp.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else { break }
                    aTracks[p.slot].append(t)
                }
                guard k < aTracks[p.slot].count else { break }
                let track = aTracks[p.slot][k]
                try insert(a, range: src, into: track, at: at, speed: seg.speed)

                let mp = params[track.trackID] ?? AVMutableAudioMixInputParameters(track: track)
                params[track.trackID] = mp
                let vol = Float(seg.volume)
                let fadeIn = p.overlapIn > 0 ? p.overlapIn : p.fadeIn
                if fadeIn > 0 {
                    mp.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol,
                                     timeRange: CMTimeRange(start: at, duration: cm(fadeIn)))
                } else {
                    mp.setVolume(vol, at: at)
                }
                if nextOverlap > 0 {
                    mp.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: cm(p.end - nextOverlap), duration: cm(nextOverlap)))
                }
            }

            items.append(RenderItem(trackID: vTracks[p.slot].trackID, start: p.start, end: p.end,
                                    overlapIn: p.overlapIn, fadeIn: p.fadeIn, transition: seg.transitionIn,
                                    crop: seg.crop, zooms: seg.zooms, orientation: info.orientation))
        }

        // Drop tracks that ended up empty.
        var usedVideo: [CMPersistentTrackID] = []
        for t in vTracks {
            if t.segments.isEmpty { comp.removeTrack(t) } else { usedVideo.append(t.trackID) }
        }
        for t in aTracks.flatMap({ $0 }) where t.segments.isEmpty {
            params[t.trackID] = nil
            comp.removeTrack(t)
        }

        let renderSize = project.preset.size(firstClip: firstSize)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = TimelineCompositor.self
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(project.fps))
        vc.instructions = [TimelineInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration),
                                               items: items, renderSize: renderSize, trackIDs: usedVideo)]

        let mix = AVMutableAudioMix()
        mix.inputParameters = Array(params.values)

        return BuiltTimeline(composition: comp, videoComposition: vc, audioMix: mix,
                             duration: comp.duration.seconds)
    }

    private static func insert(_ source: AVAssetTrack, range: CMTimeRange,
                               into track: AVMutableCompositionTrack, at: CMTime, speed: Double) throws {
        let r = range.intersection(source.timeRange)
        guard r.duration > .zero else { return }
        let offset = cm((r.start - range.start).seconds / speed)
        let time = at + offset
        let end = track.segments.isEmpty ? CMTime.zero : track.timeRange.end
        if end < time {
            track.insertEmptyTimeRange(CMTimeRange(start: end, end: time))
        }
        try track.insertTimeRange(r, of: source, at: time)
        if abs(speed - 1) > 0.0001 {
            track.scaleTimeRange(CMTimeRange(start: time, duration: r.duration),
                                 toDuration: cm(r.duration.seconds / speed))
        }
    }
}
