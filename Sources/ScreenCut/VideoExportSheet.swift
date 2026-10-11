import SwiftUI

struct VideoExportSheet: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = VideoExportSettings()
    @State private var size = CGSize(width: 1920, height: 1080)

    var body: some View {
        let bytes = settings.estimatedBytes(size: size, fps: model.project.fps, duration: model.timelineDuration)
        let mbps = Double(settings.videoBitrate(size: size, fps: model.project.fps)) / 1_000_000

        VStack(alignment: .leading, spacing: 12) {
            Text("Export Video").font(.title3).bold()
            Form {
                Picker("Format", selection: $settings.hevc) {
                    Text("H.264 (plays everywhere)").tag(false)
                    Text("HEVC (about 40% smaller, newer devices)").tag(true)
                }
                Picker("Quality", selection: $settings.quality) {
                    ForEach(ExportQuality.allCases) { Text($0.label).tag($0) }
                }
                Picker("Size", selection: Binding(get: { model.project.preset },
                                                  set: { v in model.edit { $0.preset = v } })) {
                    ForEach(OutputPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: Binding(get: { model.project.fps },
                                                        set: { v in model.edit { $0.fps = v } })) {
                    Text("24 fps").tag(24)
                    Text("30 fps (smaller)").tag(30)
                    Text("60 fps (smoother)").tag(60)
                }
            }
            .formStyle(.grouped)
            Text("\(Int(size.width)) × \(Int(size.height)) · \(String(format: "%.1f", mbps)) Mbit/s · about \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) for \(timecode(model.timelineDuration))")
                .font(.callout.monospacedDigit())
            Text("Tip: 1080p at 30 fps with Balanced quality keeps text sharp and files small for most screen recordings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let s = settings
                    dismiss()
                    DispatchQueue.main.async { model.exportPanel(settings: s) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task(id: "\(model.project.preset.rawValue)") { size = await model.outputSize() }
    }
}
