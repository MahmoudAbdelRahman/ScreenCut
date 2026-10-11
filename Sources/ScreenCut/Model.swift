import Foundation
import CoreGraphics

// MARK: - Easing

enum Easing: String, Codable, CaseIterable, Identifiable, Sendable {
    case linear, easeIn, easeOut, easeInOut, smooth, overshoot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In-Out"
        case .smooth: return "Smooth"
        case .overshoot: return "Overshoot"
        }
    }

    /// Maps 0...1 to 0...1 (overshoot may go slightly above 1).
    func apply(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        switch self {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: let u = 1 - t; return 1 - u * u * u
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .smooth: return t * t * t * (t * (t * 6 - 15) + 10)
        case .overshoot:
            let c1 = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        }
    }
}

// MARK: - Transitions

enum TransitionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, crossfade, fadeBlack, slideLeft, slideUp, wipe, zoomBlend

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None (hard cut)"
        case .crossfade: return "Crossfade"
        case .fadeBlack: return "Dip to black"
        case .slideLeft: return "Slide left"
        case .slideUp: return "Slide up"
        case .wipe: return "Wipe"
        case .zoomBlend: return "Zoom blend"
        }
    }
}

struct Transition: Codable, Equatable, Sendable {
    var kind: TransitionKind = .none
    var duration: Double = 0.6
    var easing: Easing = .easeInOut
}

// MARK: - Crop and zoom

/// Normalised rectangle, origin top-left, 0...1.
struct CropRect: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var w: Double = 1
    var h: Double = 1

    static let full = CropRect()

    var isFull: Bool { x <= 0.0001 && y <= 0.0001 && w >= 0.9999 && h >= 0.9999 }

    var clamped: CropRect {
        var c = self
        c.w = min(max(c.w, 0.02), 1)
        c.h = min(max(c.h, 0.02), 1)
        c.x = min(max(c.x, 0), 1 - c.w)
        c.y = min(max(c.y, 0), 1 - c.h)
        return c
    }
}

/// A zoom/pan move inside a clip. Times are in the clip's output time (after speed).
struct ZoomEffect: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Double = 0
    var duration: Double = 2.5
    var scale: Double = 2
    /// Focus point in the cropped source, normalised, origin top-left.
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// Seconds to zoom in and to zoom out.
    var ramp: Double = 0.5
    var easing: Easing = .easeInOut

    /// 0 = not zoomed, 1 = fully zoomed.
    func amount(at local: Double) -> Double {
        let t = local - start
        let r = min(ramp, duration / 2)
        if r <= 0.0001 { return 1 }
        if t < r { return easing.apply(t / r) }
        if t > duration - r { return easing.apply((duration - t) / r) }
        return 1
    }
}

// MARK: - Segment and project

struct Segment: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var sourcePath: String
    var sourceStart: Double
    var sourceEnd: Double
    var speed: Double = 1
    var volume: Double = 1
    var crop: CropRect = .full
    var transitionIn = Transition()
    var zooms: [ZoomEffect] = []

    var outputDuration: Double { max(0, sourceEnd - sourceStart) / speed }

    func sourceTime(atLocal local: Double) -> Double { sourceStart + local * speed }
}

enum OutputPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case source, hd1080, hd720, vertical, square

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: return "Same as first clip"
        case .hd1080: return "1920 × 1080 (16:9)"
        case .hd720: return "1280 × 720 (16:9)"
        case .vertical: return "1080 × 1920 (9:16)"
        case .square: return "1080 × 1080 (1:1)"
        }
    }

    func size(firstClip: CGSize) -> CGSize {
        switch self {
        case .source:
            var w = firstClip.width, h = firstClip.height
            if w <= 0 || h <= 0 { return CGSize(width: 1920, height: 1080) }
            let maxW: CGFloat = 3840
            if w > maxW { h = h * maxW / w; w = maxW }
            return CGSize(width: (w / 2).rounded() * 2, height: (h / 2).rounded() * 2)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .hd720: return CGSize(width: 1280, height: 720)
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }
}

struct Project: Codable, Equatable, Sendable {
    var segments: [Segment] = []
    var preset: OutputPreset = .source
    var fps: Int = 30
}

// MARK: - Timeline layout (shared by UI and renderer)

struct PlacedSegment: Identifiable, Sendable {
    var id: UUID { segment.id }
    let index: Int
    let segment: Segment
    /// Which of the two alternating composition tracks holds this clip.
    let slot: Int
    let start: Double
    let end: Double
    /// Overlap with the previous clip (transition length), 0 for hard cuts.
    let overlapIn: Double
    /// Fade-in from black for the first clip.
    let fadeIn: Double
}

enum TimelineLayout {
    static func layout(_ segments: [Segment]) -> (items: [PlacedSegment], duration: Double) {
        var items: [PlacedSegment] = []
        var cursor = 0.0
        for (i, s) in segments.enumerated() {
            let d = s.outputDuration
            var overlap = 0.0
            var fade = 0.0
            if s.transitionIn.kind != .none {
                if i == 0 {
                    fade = min(s.transitionIn.duration, d / 2)
                } else {
                    // Each clip gives at most half its length to each side, so at most two clips overlap.
                    overlap = min(s.transitionIn.duration, d / 2, segments[i - 1].outputDuration / 2)
                }
            }
            let start = max(0, cursor - overlap)
            items.append(PlacedSegment(index: i, segment: s, slot: i % 2, start: start,
                                       end: start + d, overlapIn: overlap, fadeIn: fade))
            cursor = start + d
        }
        return (items, cursor)
    }
}

func timecode(_ t: Double) -> String {
    let t = max(0, t.isFinite ? t : 0)
    let m = Int(t) / 60
    let s = Int(t) % 60
    let cs = Int((t - floor(t)) * 100)
    return String(format: "%02d:%02d.%02d", m, s, cs)
}
