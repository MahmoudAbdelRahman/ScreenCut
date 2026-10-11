import SwiftUI

@main
struct ScreenCutApp: App {
    @StateObject private var model = EditorModel()
    @StateObject private var recorder = Recorder()

    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        Window("ScreenCut", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(recorder)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear {
                    recorder.onFinished = { [weak model] url in model?.addClip(url: url) }
                    if !CommandLine.arguments.contains("--selftest") {
                        for arg in CommandLine.arguments.dropFirst() where FileManager.default.fileExists(atPath: arg) {
                            model.addClip(url: URL(fileURLWithPath: arg))
                        }
                    }
                }
        }
        .commands { AppCommands(model: model, recorder: recorder) }

        MenuBarExtra(isInserted: Binding(get: { recorder.isRecording }, set: { _ in })) {
            Button("Stop Recording") { Task { await recorder.stop() } }
        } label: {
            Label(recorder.elapsedString, systemImage: "record.circle.fill")
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: EditorModel
    @ObservedObject var recorder: Recorder

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { model.newProject() }.keyboardShortcut("n")
            Button("Open Project…") { model.openProjectPanel() }.keyboardShortcut("o")
            Divider()
            Button("Import Video…") { model.importPanel() }.keyboardShortcut("i")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") { model.saveProject() }.keyboardShortcut("s")
            Button("Save Project As…") { model.saveProject(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Export Video…") { model.showExportSheet = true }
                .keyboardShortcut("e")
                .disabled(model.project.segments.isEmpty)
            Button("Export Animated GIF…") { model.showGIFSheet = true }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(model.project.segments.isEmpty)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
            Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
        }
        CommandMenu("Record") {
            Button(recorder.isRecording ? "Stop Recording" : "Start Recording…") { recorder.toggle() }
                .keyboardShortcut("r")
        }
        CommandMenu("Clip") {
            Button("Split at Playhead") { model.splitAtPlayhead() }.keyboardShortcut("b")
            Button("Set In Point to Playhead") { model.setInToPlayhead() }.keyboardShortcut("i", modifiers: [.command, .option])
            Button("Set Out Point to Playhead") { model.setOutToPlayhead() }.keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
            Button("Delete") { model.deleteSelected() }.keyboardShortcut(.delete, modifiers: [.command])
            Button("Duplicate") { model.duplicateSelected() }.keyboardShortcut("d")
            Button("Move Left") { model.moveSelected(by: -1) }.keyboardShortcut("[")
            Button("Move Right") { model.moveSelected(by: 1) }.keyboardShortcut("]")
            Divider()
            Button("Add Zoom at Playhead") { model.addZoomAtPlayhead() }.keyboardShortcut("z", modifiers: [.command, .option])
            Button("Edit Crop…") { model.editCropOfSelected() }.keyboardShortcut("c", modifiers: [.command, .option])
        }
    }
}
