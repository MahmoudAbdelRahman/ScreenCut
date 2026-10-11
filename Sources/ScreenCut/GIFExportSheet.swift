import SwiftUI

struct GIFExportSheet: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = GIFSettings()

    var body: some View {
        let range = model.gifRange(settings)
        let length = max(0, range.end - range.start)
        let frames = Int(length * Double(settings.fps))

        VStack(alignment: .leading, spacing: 12) {
            Text("Export Animated GIF").font(.title3).bold()
            Form {
                Picker("Width", selection: $settings.width) {
                    ForEach([320, 480, 640, 800, 1024, 1280], id: \.self) { Text("\($0) px").tag($0) }
                }
                Picker("Frame rate", selection: $settings.fps) {
                    ForEach([8, 10, 12, 15, 20, 25], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Toggle("Only the selected clip", isOn: $settings.selectedClipOnly)
                    .disabled(model.selectedID == nil)
                Toggle("Loop forever", isOn: $settings.loop)
            }
            .formStyle(.grouped)
            Text("\(timecode(length)) · \(frames) frames. GIFs get big quickly: smaller width, lower frame rate and shorter clips keep the file small.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let s = settings
                    dismiss()
                    DispatchQueue.main.async { model.gifPanel(settings: s) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(frames == 0)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { settings.selectedClipOnly = false }
    }
}
