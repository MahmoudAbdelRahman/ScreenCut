import AppKit
import Foundation

/// Developer check: `ScreenCut --selftest in.mov out.mp4` builds a small edit and exports it.
enum SelfTest {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 2 else { return }
        let input = args[i + 1], output = args[i + 2]
        Task { @MainActor in
            let model = EditorModel()
            do {
                let info = try await model.cache.info(for: input)
                let d = info.duration
                var a = Segment(name: "A", sourcePath: input, sourceStart: 0, sourceEnd: d * 0.5)
                a.transitionIn = Transition(kind: .fadeBlack, duration: 0.5, easing: .easeOut)
                a.zooms = [ZoomEffect(start: 0.5, duration: 2, scale: 2.5, centerX: 0.8, centerY: 0.2,
                                      ramp: 0.6, easing: .easeInOut)]
                var b = Segment(name: "B", sourcePath: input, sourceStart: d * 0.5, sourceEnd: d)
                b.speed = 2
                b.crop = CropRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
                b.transitionIn = Transition(kind: .crossfade, duration: 0.8, easing: .smooth)
                var c = Segment(name: "C", sourcePath: input, sourceStart: 0, sourceEnd: min(2, d))
                c.transitionIn = Transition(kind: .slideLeft, duration: 0.6, easing: .overshoot)
                model.project = Project(segments: [a, b, c], preset: .hd720, fps: 30)
                if output.hasSuffix(".gif") {
                    await model.exportGIF(to: URL(fileURLWithPath: output), settings: GIFSettings(width: 480, fps: 12))
                } else {
                    await model.export(to: URL(fileURLWithPath: output), settings: VideoExportSettings(hevc: args.contains("--hevc"), quality: .balanced))
                }
                if let e = model.errorMessage { print("SELFTEST FAIL: \(e)"); exit(1) }
                print("SELFTEST OK: timeline \(model.timelineDuration)s -> \(output)")
                exit(0)
            } catch {
                print("SELFTEST FAIL: \(error)")
                exit(1)
            }
        }
    }
}
