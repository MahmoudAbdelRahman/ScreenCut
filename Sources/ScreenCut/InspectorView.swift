import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        Group {
            if let id = model.selectedID, model.segment(id) != nil {
                SegmentInspector(id: id)
            } else {
                ProjectInspector()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ProjectInspector: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        Form {
            Section("Project") {
                Picker("Output size", selection: Binding(get: { model.project.preset },
                                                         set: { v in model.edit { $0.preset = v } })) {
                    ForEach(OutputPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: Binding(get: { model.project.fps },
                                                        set: { v in model.edit { $0.fps = v } })) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                LabeledContent("Length", value: timecode(model.timelineDuration))
            }
            Section("Shortcuts") {
                shortcut("Play / pause", "space")
                shortcut("Previous / next frame", "← →")
                shortcut("Split at playhead", "⌘B")
                shortcut("Set in / out to playhead", "⌥⌘I  ⌥⌘O")
                shortcut("Delete clip or zoom", "⌘⌫")
                shortcut("Move clip", "⌘[  ⌘]")
                shortcut("Add zoom", "⌥⌘Z")
                shortcut("Crop", "⌥⌘C")
                shortcut("Record", "⌘R")
                shortcut("Export MP4", "⌘E")
                shortcut("Export GIF", "⌥⌘G")
            }
            Section {
                Text("Click a clip in the timeline to edit it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ name: String, _ keys: String) -> some View {
        LabeledContent(name) { Text(keys).font(.system(.body, design: .monospaced)) }
    }
}

struct SegmentInspector: View {
    @EnvironmentObject var model: EditorModel
    let id: UUID

    var body: some View {
        let seg = model.segmentBinding(id)
        let s = seg.wrappedValue
        let sourceDuration = model.sourceDurations[s.sourcePath] ?? s.sourceEnd

        Form {
            Section("Clip") {
                LabeledContent("Name", value: s.name)
                LabeledContent("Length", value: timecode(s.outputDuration))
                LabeledContent("In") {
                    HStack {
                        TextField("", value: seg.sourceStart, format: .number.precision(.fractionLength(2)))
                            .frame(width: 70)
                        Button("Playhead") { model.setInToPlayhead() }.controlSize(.small)
                    }
                }
                LabeledContent("Out") {
                    HStack {
                        TextField("", value: seg.sourceEnd, format: .number.precision(.fractionLength(2)))
                            .frame(width: 70)
                        Button("Playhead") { model.setOutToPlayhead() }.controlSize(.small)
                    }
                }
                Text("Source is \(timecode(sourceDuration)) long.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Speed and sound") {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: seg.speed, in: 0.25...4)
                        Menu(String(format: "%.2g×", s.speed)) {
                            ForEach([0.25, 0.5, 1, 1.5, 2, 4, 8, 16], id: \.self) { v in
                                Button(String(format: "%g×", v)) { seg.wrappedValue.speed = v }
                            }
                        }
                        .frame(width: 70)
                    }
                }
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: seg.volume, in: 0...2)
                        Text("\(Int(s.volume * 100))%").monospacedDigit().frame(width: 44)
                    }
                }
            }

            Section("Crop") {
                LabeledContent("Area", value: s.crop.isFull ? "Full frame"
                               : String(format: "%.0f%% × %.0f%%", s.crop.w * 100, s.crop.h * 100))
                HStack {
                    Button("Edit Crop…") { model.editCropOfSelected() }
                    Button("Reset") { seg.wrappedValue.crop = .full }.disabled(s.crop.isFull)
                    Button("Apply to All") { model.applyCropToAll(s.crop) }
                }
            }

            Section("Transition in") {
                Picker("Type", selection: seg.transitionIn.kind) {
                    ForEach(TransitionKind.allCases) { Text($0.label).tag($0) }
                }
                if s.transitionIn.kind != .none {
                    LabeledContent("Duration") {
                        HStack {
                            Slider(value: seg.transitionIn.duration, in: 0.1...3)
                            Text(String(format: "%.1fs", s.transitionIn.duration)).monospacedDigit().frame(width: 40)
                        }
                    }
                    EasingPicker(easing: seg.transitionIn.easing)
                    if model.placed.first(where: { $0.id == id })?.index == 0 {
                        Text("First clip: fades in from black.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Zoom and pan") {
                ForEach(seg.zooms) { $z in
                    ZoomEditor(zoom: $z, segmentID: id, clipLength: s.outputDuration)
                }
                Button {
                    model.addZoomAtPlayhead()
                } label: {
                    Label("Add Zoom at Playhead", systemImage: "plus.magnifyingglass")
                }
            }

            Section {
                HStack {
                    Button("Split") { model.splitAtPlayhead() }
                    Button("Duplicate") { model.duplicateSelected() }
                    Spacer()
                    Button("Delete Clip", role: .destructive) {
                        model.selectedZoomID = nil
                        model.deleteSelected()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ZoomEditor: View {
    @EnvironmentObject var model: EditorModel
    @Binding var zoom: ZoomEffect
    let segmentID: UUID
    let clipLength: Double

    var body: some View {
        let selected = model.selectedZoomID == zoom.id
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "Zoom %.1f× at %@", zoom.scale, timecode(zoom.start))).bold()
                Spacer()
                Button {
                    model.frameEditor = FrameEditorRequest(segmentID: segmentID, mode: .focus(zoom.id))
                } label: { Image(systemName: "scope") }
                    .help("Pick focus point")
                Button {
                    let zid = zoom.id
                    model.updateSegment(segmentID, coalesce: false) { $0.zooms.removeAll { $0.id == zid } }
                } label: { Image(systemName: "trash") }
                    .help("Remove this zoom")
            }
            .buttonStyle(.borderless)
            row("Start") { Slider(value: $zoom.start, in: 0...max(clipLength, 0.1)) }
            row("Length") { Slider(value: $zoom.duration, in: 0.3...max(clipLength, 0.4)) }
            row("Zoom") { Slider(value: $zoom.scale, in: 1.1...5) }
            row("Ramp") { Slider(value: $zoom.ramp, in: 0...2) }
            EasingPicker(easing: $zoom.easing)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.purple.opacity(0.15) : .clear))
        .onTapGesture { model.selectedZoomID = zoom.id }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).frame(width: 50, alignment: .leading).foregroundStyle(.secondary)
            content()
        }
    }
}

struct EasingPicker: View {
    @Binding var easing: Easing

    var body: some View {
        HStack {
            Picker("Easing", selection: $easing) {
                ForEach(Easing.allCases) { Text($0.label).tag($0) }
            }
            EasingCurve(easing: easing)
        }
    }
}

struct EasingCurve: View {
    let easing: Easing

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for i in 0...40 {
                let x = Double(i) / 40
                let y = easing.apply(x)
                let pt = CGPoint(x: x * size.width, y: size.height * (0.9 - 0.8 * y))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.stroke(path, with: .color(.accentColor), lineWidth: 2)
        }
        .frame(width: 44, height: 26)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
    }
}
