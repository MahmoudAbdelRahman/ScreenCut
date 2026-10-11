import SwiftUI

enum AspectLock: String, CaseIterable, Identifiable {
    case free, source, wide, vertical, square, classic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: return "Free"
        case .source: return "Original"
        case .wide: return "16:9"
        case .vertical: return "9:16"
        case .square: return "1:1"
        case .classic: return "4:3"
        }
    }

    func ratio(imageAspect: Double) -> Double? {
        switch self {
        case .free: return nil
        case .source: return imageAspect
        case .wide: return 16.0 / 9
        case .vertical: return 9.0 / 16
        case .square: return 1
        case .classic: return 4.0 / 3
        }
    }
}

/// Shows one frame of a clip. Crop mode: drag a rectangle. Focus mode: click the zoom target.
struct FrameEditorSheet: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    let request: FrameEditorRequest

    @State private var image: CGImage?
    @State private var crop = CropRect.full
    @State private var focus = CGPoint(x: 0.5, y: 0.5)
    @State private var zoomScale = 2.0
    @State private var aspect = AspectLock.free

    @State private var dragMode: DragMode?
    @State private var originCrop = CropRect.full
    @State private var anchor = CGPoint.zero

    private enum DragMode { case move, resize }

    private var isCrop: Bool { if case .crop = request.mode { return true } else { return false } }

    var body: some View {
        VStack(spacing: 12) {
            Text(isCrop ? "Drag to choose the area to keep. Drag inside to move it, drag a corner to resize."
                        : "Click the point the zoom should move to.")
                .font(.headline)
            GeometryReader { geo in
                if let image {
                    let iw = CGFloat(image.width), ih = CGFloat(image.height)
                    let s = min(geo.size.width / iw, geo.size.height / ih)
                    let d = CGRect(x: (geo.size.width - iw * s) / 2, y: (geo.size.height - ih * s) / 2,
                                   width: iw * s, height: ih * s)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: d.width, height: d.height)
                            .offset(x: d.minX, y: d.minY)
                        if isCrop { cropOverlay(d, pixel: CGSize(width: iw, height: ih)) } else { focusOverlay(d) }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { handleDrag($0, d) }
                        .onEnded { _ in dragMode = nil })
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack {
                if isCrop {
                    Picker("Aspect", selection: $aspect) {
                        ForEach(AspectLock.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 180)
                    .onChange(of: aspect) { applyAspectToCurrent() }
                    Button("Full Frame") { crop = .full }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 880, minHeight: 620)
        .task { await load() }
    }

    // MARK: overlays

    private func viewRect(_ d: CGRect) -> CGRect {
        CGRect(x: d.minX + crop.x * d.width, y: d.minY + crop.y * d.height,
               width: crop.w * d.width, height: crop.h * d.height)
    }

    @ViewBuilder
    private func cropOverlay(_ d: CGRect, pixel: CGSize) -> some View {
        let r = viewRect(d)
        Path { p in
            p.addRect(d)
            p.addRect(r)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        Rectangle()
            .stroke(Color.yellow, lineWidth: 2)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
        ForEach(0..<4, id: \.self) { i in
            let pt = CGPoint(x: i % 2 == 0 ? r.minX : r.maxX, y: i < 2 ? r.minY : r.maxY)
            Circle().fill(Color.yellow).frame(width: 12, height: 12)
                .offset(x: pt.x - 6, y: pt.y - 6)
        }
        Text("\(Int(crop.w * pixel.width)) × \(Int(crop.h * pixel.height))")
            .font(.caption.monospacedDigit())
            .padding(4)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
            .offset(x: r.minX + 6, y: r.minY + 6)
    }

    @ViewBuilder
    private func focusOverlay(_ d: CGRect) -> some View {
        let w = d.width / zoomScale, h = d.height / zoomScale
        let cx = min(max(d.minX + focus.x * d.width, d.minX + w / 2), d.maxX - w / 2)
        let cy = min(max(d.minY + focus.y * d.height, d.minY + h / 2), d.maxY - h / 2)
        Rectangle()
            .stroke(Color.purple, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .frame(width: w, height: h)
            .offset(x: cx - w / 2, y: cy - h / 2)
        Image(systemName: "scope")
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.yellow)
            .shadow(radius: 2)
            .frame(width: 30, height: 30)
            .offset(x: d.minX + focus.x * d.width - 15, y: d.minY + focus.y * d.height - 15)
    }

    // MARK: interaction

    private func handleDrag(_ v: DragGesture.Value, _ d: CGRect) {
        func norm(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max((p.x - d.minX) / d.width, 0), 1), y: min(max((p.y - d.minY) / d.height, 0), 1))
        }
        let start = norm(v.startLocation)
        let cur = norm(v.location)
        guard isCrop else { focus = cur; return }

        if dragMode == nil {
            originCrop = crop
            let r = viewRect(d)
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            if let i = corners.firstIndex(where: { hypot($0.x - v.startLocation.x, $0.y - v.startLocation.y) < 16 }) {
                let opp = corners[3 - i]
                anchor = norm(opp)
                dragMode = .resize
            } else if r.contains(v.startLocation) {
                dragMode = .move
            } else {
                anchor = start
                dragMode = .resize
            }
        }
        switch dragMode {
        case .move:
            var c = originCrop
            c.x = min(max(originCrop.x + cur.x - start.x, 0), 1 - c.w)
            c.y = min(max(originCrop.y + cur.y - start.y, 0), 1 - c.h)
            crop = c
        case .resize:
            crop = rect(from: anchor, to: cur, imageAspect: d.width / d.height)
        case nil:
            break
        }
    }

    private func rect(from a: CGPoint, to b: CGPoint, imageAspect: Double) -> CropRect {
        var w = abs(b.x - a.x), h = abs(b.y - a.y)
        if let r = aspect.ratio(imageAspect: imageAspect) {
            let maxW = b.x >= a.x ? 1 - a.x : a.x
            let maxH = b.y >= a.y ? 1 - a.y : a.y
            h = w * imageAspect / r
            if h > maxH { h = maxH; w = h * r / imageAspect }
            if w > maxW { w = maxW; h = w * imageAspect / r }
        }
        w = max(w, 0.02)
        h = max(h, 0.02)
        let x = b.x >= a.x ? a.x : a.x - w
        let y = b.y >= a.y ? a.y : a.y - h
        return CropRect(x: x, y: y, w: w, h: h).clamped
    }

    private func applyAspectToCurrent() {
        guard let image, let r = aspect.ratio(imageAspect: Double(image.width) / Double(image.height)) else { return }
        let ia = Double(image.width) / Double(image.height)
        var c = crop
        let cx = c.x + c.w / 2, cy = c.y + c.h / 2
        c.h = c.w * ia / r
        if c.h > 1 { c.h = 1; c.w = c.h * r / ia }
        c.x = cx - c.w / 2
        c.y = cy - c.h / 2
        crop = c.clamped
    }

    // MARK: load / apply

    private func load() async {
        guard let seg = model.segment(request.segmentID) else { return }
        crop = seg.crop
        if case .focus(let zid) = request.mode, let z = seg.zooms.first(where: { $0.id == zid }) {
            focus = CGPoint(x: z.centerX, y: z.centerY)
            zoomScale = z.scale
        }
        guard let full = await model.frameImage(path: seg.sourcePath, time: model.editorSourceTime(for: seg),
                                                maxSize: 1800) else { return }
        if isCrop {
            image = full
        } else {
            // Zoom focus is relative to the cropped picture.
            let W = CGFloat(full.width), H = CGFloat(full.height)
            let r = CGRect(x: seg.crop.x * W, y: seg.crop.y * H, width: seg.crop.w * W, height: seg.crop.h * H).integral
            image = full.cropping(to: r) ?? full
        }
    }

    private func apply() {
        switch request.mode {
        case .crop:
            let c = crop
            model.updateSegment(request.segmentID, coalesce: false) { $0.crop = c }
        case .focus(let zid):
            let f = focus
            model.updateSegment(request.segmentID, coalesce: false) { s in
                if let i = s.zooms.firstIndex(where: { $0.id == zid }) {
                    s.zooms[i].centerX = f.x
                    s.zooms[i].centerY = f.y
                }
            }
        }
    }
}
