import AVKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: EditorModel
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        if model.project.segments.isEmpty {
                            EmptyStateView()
                        } else {
                            PlayerContainer(player: model.player)
                        }
                    }
                    Divider()
                    TransportBar()
                }
                .frame(minWidth: 560)
                InspectorView()
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            }
            Divider()
            TimelineView()
                .frame(height: 178)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    recorder.toggle()
                } label: {
                    if recorder.isRecording {
                        Label("Stop \(recorder.elapsedString)", systemImage: "stop.circle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Label("Record", systemImage: "record.circle")
                    }
                }
                .help("Record a screen, window or app (⌘R)")
                Menu {
                    Toggle("System audio", isOn: $recorder.captureSystemAudio)
                    Toggle("Microphone", isOn: $recorder.captureMicrophone)
                    Toggle("Show cursor", isOn: $recorder.showCursor)
                    Toggle("Hide Mahmoud while recording", isOn: $recorder.hideAppWhileRecording)
                    Divider()
                    Toggle("Record at 60 fps (larger files)", isOn: $recorder.record60fps)
                    Toggle("Compact recordings (HEVC)", isOn: $recorder.recordHEVC)
                } label: {
                    Label("Recording options", systemImage: "slider.horizontal.3")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.importPanel() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import video files (⌘I)")
                Menu {
                    Button("Video (MP4)…") { model.showExportSheet = true }
                    Button("Animated GIF…") { model.showGIFSheet = true }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                } primaryAction: {
                    model.showExportSheet = true
                }
                .help("Click: export video (⌘E). Arrow: animated GIF (⌥⌘G)")
                .disabled(model.project.segments.isEmpty)
            }
        }
        .navigationTitle(model.projectURL?.deletingPathExtension().lastPathComponent ?? "Mahmoud")
        .sheet(item: $model.frameEditor) { req in
            FrameEditorSheet(request: req).environmentObject(model)
        }
        .sheet(isPresented: $model.showGIFSheet) {
            GIFExportSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showExportSheet) {
            VideoExportSheet().environmentObject(model)
        }
        .overlay {
            if let p = model.exportProgress {
                ZStack {
                    Color.black.opacity(0.35)
                    VStack(spacing: 10) {
                        Text("Exporting… \(Int(p * 100))%").font(.headline)
                        ProgressView(value: p).frame(width: 260)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .alert("Mahmoud", isPresented: Binding(get: { model.errorMessage != nil },
                                                 set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Recording", isPresented: Binding(get: { recorder.lastError != nil },
                                                 set: { if !$0 { recorder.lastError = nil } })) {
            Button("OK") { recorder.lastError = nil }
        } message: {
            Text(recorder.lastError ?? "")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.addClip(url: url) } }
                }
            }
            return true
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: EditorModel
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Record your screen or import a video").font(.title3).foregroundStyle(.white)
            HStack {
                Button("Record Screen…") { recorder.start() }.controlSize(.large)
                Button("Import Video…") { model.importPanel() }.controlSize(.large)
            }
            Text("You can also drop video files here.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PlayerContainer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

struct TransportBar: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Button { model.seek(0) } label: { Image(systemName: "backward.end.fill") }
                .help("Go to start")
            Button { model.stepFrame(-1) } label: { Image(systemName: "backward.frame.fill") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous frame (←)")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (space)")
            Button { model.stepFrame(1) } label: { Image(systemName: "forward.frame.fill") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next frame (→)")
            Text("\(timecode(model.currentTime)) / \(timecode(model.timelineDuration))")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }
                .help("Split clip at playhead (⌘B)")
            Button { model.addZoomAtPlayhead() } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
                .help("Add a zoom/pan at playhead (⌥⌘Z)")
            Button { model.editCropOfSelected() } label: { Label("Crop", systemImage: "crop") }
                .help("Crop the selected clip (⌥⌘C)")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .disabled(model.project.segments.isEmpty)
    }
}
