@preconcurrency import AVFoundation
import CoreImage

// MARK: - Per-frame description of one clip

struct RenderItem: Sendable {
    let trackID: CMPersistentTrackID
    let start: Double
    let end: Double
    let overlapIn: Double
    let fadeIn: Double
    let transition: Transition
    let crop: CropRect
    let zooms: [ZoomEffect]
    let orientation: CGImagePropertyOrientation
}

// MARK: - Instruction + custom compositor

final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let items: [RenderItem]
    let renderSize: CGSize

    init(timeRange: CMTimeRange, items: [RenderItem], renderSize: CGSize, trackIDs: [CMPersistentTrackID]) {
        self.timeRange = timeRange
        self.items = items
        self.renderSize = renderSize
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
    }
}

final class TimelineCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])

    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelAttributes }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let ins = request.videoCompositionInstruction as? TimelineInstruction,
                  let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "ScreenCut", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: "Cannot render frame"]))
                return
            }
            let t = request.compositionTime.seconds
            let image = FrameRenderer.render(at: t, items: ins.items, size: ins.renderSize) { id in
                request.sourceFrame(byTrackID: id).map { CIImage(cvPixelBuffer: $0) }
            }
            context.render(image, to: out, bounds: CGRect(origin: .zero, size: ins.renderSize), colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

// MARK: - Core Image frame renderer

enum FrameRenderer {
    static func render(at t: Double, items: [RenderItem], size: CGSize,
                       source: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let black = CIImage(color: CIColor.black).cropped(to: canvas)

        var active = items.filter { t >= $0.start - 0.0005 && t < $0.end }
        if active.isEmpty, let last = items.last, t >= last.start { active = [last] }

        let layers: [(RenderItem, CIImage)] = active.compactMap { item in
            guard let src = source(item.trackID) else { return nil }
            return (item, layer(item, src, local: t - item.start, canvas: canvas, black: black))
        }
        guard let first = layers.first else { return black }

        if layers.count == 1 {
            let (item, img) = first
            let lt = t - item.start
            if item.fadeIn > 0, lt < item.fadeIn {
                return dim(img, item.transition.easing.apply(lt / item.fadeIn))
            }
            return img
        }

        let a = layers[0].1
        let (bItem, b) = layers[1]
        let p = bItem.transition.easing.apply((t - bItem.start) / max(bItem.overlapIn, 0.001))
        let pc = min(max(p, 0), 1)
        let w = size.width, h = size.height

        switch bItem.transition.kind {
        case .none, .crossfade:
            return alpha(b, pc).composited(over: a)
        case .fadeBlack:
            return pc < 0.5 ? dim(a, 1 - 2 * pc) : dim(b, 2 * pc - 1)
        case .slideLeft:
            let bt = b.transformed(by: CGAffineTransform(translationX: (1 - p) * w, y: 0))
            let at = a.transformed(by: CGAffineTransform(translationX: -p * w, y: 0))
            return bt.composited(over: at).composited(over: black).cropped(to: canvas)
        case .slideUp:
            let bt = b.transformed(by: CGAffineTransform(translationX: 0, y: -(1 - p) * h))
            let at = a.transformed(by: CGAffineTransform(translationX: 0, y: p * h))
            return bt.composited(over: at).composited(over: black).cropped(to: canvas)
        case .wipe:
            return b.cropped(to: CGRect(x: 0, y: 0, width: pc * w, height: h)).composited(over: a)
        case .zoomBlend:
            let s = 1 + 0.6 * pc
            let tr = CGAffineTransform(translationX: -w / 2, y: -h / 2)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: w / 2, y: h / 2))
            return alpha(a.transformed(by: tr), 1 - pc).composited(over: b).cropped(to: canvas)
        }
    }

    /// One clip drawn onto a full black canvas: orientation, crop, fit, zoom.
    static func layer(_ item: RenderItem, _ src: CIImage, local lt: Double,
                      canvas: CGRect, black: CIImage) -> CIImage {
        var img = src
        if item.orientation != .up { img = img.oriented(item.orientation) }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let W = img.extent.width, H = img.extent.height

        let c = item.crop
        let cr = CGRect(x: c.x * W, y: (1 - c.y - c.h) * H, width: c.w * W, height: c.h * H)
        img = img.cropped(to: cr)

        let s = min(canvas.width / cr.width, canvas.height / cr.height)
        let tx = (canvas.width - cr.width * s) / 2
        let ty = (canvas.height - cr.height * s) / 2
        var tr = CGAffineTransform(translationX: -cr.minX, y: -cr.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))

        if let z = item.zooms.first(where: { lt >= $0.start && lt <= $0.start + $0.duration }) {
            let a = z.amount(at: lt)
            let zoom = 1 + (z.scale - 1) * a
            let cw = canvas.width, ch = canvas.height
            // Focus point on the canvas (Core Image has origin bottom-left).
            let px = tx + z.centerX * cr.width * s
            let py = ty + (1 - z.centerY) * cr.height * s
            // Keep the fully zoomed view inside the canvas.
            let hw = cw / (2 * z.scale), hh = ch / (2 * z.scale)
            let fx = min(max(px, hw), cw - hw)
            let fy = min(max(py, hh), ch - hh)
            let cx = cw / 2 + (fx - cw / 2) * a
            let cy = ch / 2 + (fy - ch / 2) * a
            tr = tr.concatenating(CGAffineTransform(translationX: -cx, y: -cy))
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                .concatenating(CGAffineTransform(translationX: cw / 2, y: ch / 2))
        }

        img = img.transformed(by: tr, highQualityDownsample: true)
        return img.composited(over: black).cropped(to: canvas)
    }

    static func alpha(_ img: CIImage, _ a: Double) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }

    static func dim(_ img: CIImage, _ k: Double) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        ])
    }
}
