import SwiftUI

private let rulerHeight: CGFloat = 22
private let clipY: CGFloat = 30
private let clipHeight: CGFloat = 64
private let zoomY: CGFloat = 100

struct TimelineView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        let pps = model.pixelsPerSecond
        let width = max(model.timelineDuration, 1) * pps + 300

        VStack(spacing: 0) {
            HStack {
                Text("Timeline").font(.headline)
                Text("\(model.project.segments.count) clips · drag to reorder · drag the yellow edges to trim")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $model.pixelsPerSecond, in: 4...300).frame(width: 160)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            model.seek(v.location.x / pps)
                        })
                    RulerView(pps: pps)
                        .frame(width: width, height: rulerHeight)
                        .allowsHitTesting(false)
                    ForEach(model.placed) { p in
                        ClipBlock(p: p, pps: pps)
                            .offset(x: p.start * pps, y: clipY)
                    }
                    ForEach(model.placed) { p in
                        ForEach(p.segment.zooms) { z in
                            ZoomBar(p: p, zoom: z, pps: pps)
                                .offset(x: (p.start + z.start) * pps, y: zoomY)
                        }
                    }
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2, height: 128)
                        .offset(x: model.currentTime * pps - 1)
                        .allowsHitTesting(false)
                }
                .frame(width: width, height: 128, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct RulerView: View {
    let pps: Double

    var body: some View {
        Canvas { ctx, size in
            let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
            let major = steps.first { $0 * pps >= 70 } ?? 600
            let minor = major / 5
            var i = 0
            while Double(i) * minor * pps < size.width {
                let t = Double(i) * minor
                let x = t * pps
                let isMajor = i % 5 == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: isMajor ? 6 : 14))
                path.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(path, with: .color(.secondary.opacity(isMajor ? 0.8 : 0.4)), lineWidth: 1)
                if isMajor {
                    let label = major < 1 ? String(format: "%.2fs", t) : timecode(t).replacingOccurrences(of: ".00", with: "")
                    ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 3, y: 6), anchor: .leading)
                }
                i += 1
            }
        }
    }
}

struct ClipBlock: View {
    @EnvironmentObject var model: EditorModel
    let p: PlacedSegment
    let pps: Double

    @State private var dragX: CGFloat = 0
    @State private var trimOrigin: Segment?

    private var selected: Bool { model.selectedID == p.id }

    var body: some View {
        let w = max(6, (p.end - p.start) * pps)
        let seg = p.segment

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(p.slot == 0 ? Color.blue.opacity(0.55) : Color.teal.opacity(0.55))
            HStack(spacing: 6) {
                if let img = model.thumbnail(for: seg) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: min(w, 96), height: clipHeight)
                        .clipped()
                }
                if w > 130 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(seg.name).font(.caption).bold().lineLimit(1)
                        HStack(spacing: 4) {
                            Text(timecode(seg.outputDuration))
                            if abs(seg.speed - 1) > 0.001 { Text(String(format: "%.2g×", seg.speed)) }
                            if !seg.crop.isFull { Image(systemName: "crop") }
                            if seg.transitionIn.kind != .none { Image(systemName: "rectangle.lefthalf.inset.filled.arrow.left") }
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .foregroundStyle(.white)
                }
            }
            if p.overlapIn > 0 || p.fadeIn > 0 {
                let tw = max(p.overlapIn, p.fadeIn) * pps
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: tw, y: 0))
                    path.addLine(to: CGPoint(x: 0, y: clipHeight))
                    path.closeSubpath()
                }
                .fill(Color.white.opacity(0.35))
                .frame(width: tw, height: clipHeight)
                .allowsHitTesting(false)
            }
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.yellow : Color.black.opacity(0.35), lineWidth: selected ? 2 : 1)
                .allowsHitTesting(false)
            if selected {
                HStack {
                    trimHandle(left: true)
                    Spacer(minLength: 0)
                    trimHandle(left: false)
                }
            }
        }
        .frame(width: w, height: clipHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .offset(x: dragX)
        .zIndex(selected ? 1 : 0)
        .onTapGesture {
            model.selectedID = p.id
            model.selectedZoomID = nil
        }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { v in
                    model.selectedID = p.id
                    dragX = v.translation.width
                }
                .onEnded { v in
                    let mid = (p.start + p.end) / 2 + v.translation.width / pps
                    dragX = 0
                    model.move(p.id, toTimelinePosition: mid)
                }
        )
        .contextMenu {
            Button("Split at Playhead") { model.splitAtPlayhead() }
            Button("Duplicate") { model.selectedID = p.id; model.duplicateSelected() }
            Button("Edit Crop…") { model.selectedID = p.id; model.editCropOfSelected() }
            Divider()
            Button("Delete") { model.selectedID = p.id; model.selectedZoomID = nil; model.deleteSelected() }
        }
    }

    private func trimHandle(left: Bool) -> some View {
        Rectangle()
            .fill(Color.yellow)
            .frame(width: 7, height: clipHeight)
            .overlay(Capsule().fill(Color.black.opacity(0.5)).frame(width: 2, height: 18))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if trimOrigin == nil {
                            trimOrigin = p.segment
                            model.updateSegment(p.id, coalesce: false) { _ in }
                        }
                        guard let o = trimOrigin else { return }
                        let delta = v.translation.width / pps * o.speed
                        model.updateSegment(p.id, coalesce: true) { s in
                            if left {
                                s.sourceStart = min(o.sourceStart + delta, s.sourceEnd - 0.1)
                            } else {
                                s.sourceEnd = max(o.sourceEnd + delta, s.sourceStart + 0.1)
                            }
                        }
                    }
                    .onEnded { _ in trimOrigin = nil }
            )
    }
}

struct ZoomBar: View {
    @EnvironmentObject var model: EditorModel
    let p: PlacedSegment
    let zoom: ZoomEffect
    let pps: Double

    var body: some View {
        let selected = model.selectedZoomID == zoom.id
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.purple.opacity(selected ? 1 : 0.65))
            .overlay(
                Text(String(format: "%.1f×", zoom.scale))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            )
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? Color.yellow : .clear, lineWidth: 1.5))
            .frame(width: max(4, zoom.duration * pps), height: 16)
            .onTapGesture {
                model.selectedID = p.id
                model.selectedZoomID = zoom.id
            }
            .help("Zoom \(String(format: "%.1f×", zoom.scale)) — select, then edit in the inspector")
    }
}
