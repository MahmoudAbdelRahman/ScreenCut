import AppKit
@preconcurrency import AVFoundation
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct FrameEditorRequest: Identifiable {
    enum Mode { case crop, focus(UUID) }
    let id = UUID()
    let segmentID: UUID
    let mode: Mode
}

struct GIFSettings {
    var width = 640
    var fps = 12
    var selectedClipOnly = false
    var loop = true
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var showGIFSheet = false
    @Published var showExportSheet = false
    @Published var project = Project() { didSet { projectChanged() } }
    @Published var selectedID: UUID?
    @Published var selectedZoomID: UUID?
    @Published private(set) var placed: [PlacedSegment] = []
    @Published private(set) var timelineDuration: Double = 0
    @Published var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var pixelsPerSecond: Double = 40
    @Published var exportProgress: Double?
    @Published var errorMessage: String?
    @Published var frameEditor: FrameEditorRequest?
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var sourceDurations: [String: Double] = [:]
    @Published private(set) var projectURL: URL?

    let player = AVPlayer()
    let cache = SourceCache()

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var lastCoalescedEdit = Date.distantPast
    private var rebuildTask: Task<Void, Never>?
    private var pendingThumbs = Set<String>()
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30),
                                                      queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.currentTime = t.seconds
            }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.isPlaying = (s != .paused) }
            .store(in: &cancellables)
    }

    // MARK: - Selection helpers

    var selectedSegment: Segment? {
        guard let id = selectedID else { return nil }
        return project.segments.first { $0.id == id }
    }

    func segment(_ id: UUID) -> Segment? { project.segments.first { $0.id == id } }

    func placedSegment(at t: Double) -> PlacedSegment? {
        placed.last { t >= $0.start && t < $0.end } ?? (t >= timelineDuration ? placed.last : nil)
    }

    /// Source time for the frame editor: playhead if it is inside the clip, else the clip middle.
    func editorSourceTime(for seg: Segment) -> Double {
        if let p = placed.first(where: { $0.id == seg.id }), currentTime >= p.start, currentTime < p.end {
            return seg.sourceTime(atLocal: currentTime - p.start)
        }
        return (seg.sourceStart + seg.sourceEnd) / 2
    }

    // MARK: - Editing with undo

    func edit(coalesce: Bool = false, _ change: (inout Project) -> Void) {
        let now = Date()
        if !coalesce || now.timeIntervalSince(lastCoalescedEdit) > 0.8 {
            undoStack.append(project)
            if undoStack.count > 300 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastCoalescedEdit = coalesce ? now : .distantPast
        var p = project
        change(&p)
        project = sanitized(p)
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(project)
        project = prev
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
    }

    func segmentBinding(_ id: UUID) -> Binding<Segment> {
        Binding(
            get: { [weak self] in
                self?.segment(id) ?? Segment(name: "", sourcePath: "", sourceStart: 0, sourceEnd: 0)
            },
            set: { [weak self] new in
                self?.edit(coalesce: true) { p in
                    if let i = p.segments.firstIndex(where: { $0.id == id }) { p.segments[i] = new }
                }
            })
    }

    func updateSegment(_ id: UUID, coalesce: Bool = true, _ change: (inout Segment) -> Void) {
        edit(coalesce: coalesce) { p in
            if let i = p.segments.firstIndex(where: { $0.id == id }) { change(&p.segments[i]) }
        }
    }

    private func sanitized(_ p: Project) -> Project {
        var p = p
        for i in p.segments.indices {
            var s = p.segments[i]
            let dur = sourceDurations[s.sourcePath] ?? .greatestFiniteMagnitude
            s.speed = min(max(s.speed, 0.1), 16)
            s.volume = min(max(s.volume, 0), 2)
            s.sourceStart = min(max(s.sourceStart, 0), max(0, dur - 0.1))
            s.sourceEnd = min(max(s.sourceEnd, s.sourceStart + 0.1), dur)
            s.crop = s.crop.clamped
            s.transitionIn.duration = min(max(s.transitionIn.duration, 0.05), 5)
            for z in s.zooms.indices {
                s.zooms[z].duration = max(s.zooms[z].duration, 0.2)
                s.zooms[z].start = max(s.zooms[z].start, 0)
                s.zooms[z].scale = min(max(s.zooms[z].scale, 1), 8)
                s.zooms[z].ramp = max(s.zooms[z].ramp, 0)
                s.zooms[z].centerX = min(max(s.zooms[z].centerX, 0), 1)
                s.zooms[z].centerY = min(max(s.zooms[z].centerY, 0), 1)
            }
            p.segments[i] = s
        }
        return p
    }

    // MARK: - Clip operations

    func splitAtPlayhead() {
        guard let p = placedSegment(at: currentTime) else { return }
        let local = currentTime - p.start
        guard local > 0.05, local < (p.end - p.start) - 0.05 else { return }
        let seg = p.segment
        let cut = seg.sourceTime(atLocal: local)
        var left = seg
        left.sourceEnd = cut
        left.zooms = seg.zooms.filter { $0.start < local }
        for i in left.zooms.indices {
            left.zooms[i].duration = min(left.zooms[i].duration, local - left.zooms[i].start)
        }
        var right = seg
        right.id = UUID()
        right.sourceStart = cut
        right.transitionIn = Transition()
        right.zooms = seg.zooms.filter { $0.start >= local }.map { z in
            var z = z
            z.id = UUID()
            z.start -= local
            return z
        }
        edit { proj in
            guard let i = proj.segments.firstIndex(where: { $0.id == seg.id }) else { return }
            proj.segments[i] = left
            proj.segments.insert(right, at: i + 1)
        }
        selectedID = right.id
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        if let zid = selectedZoomID {
            updateSegment(id, coalesce: false) { $0.zooms.removeAll { $0.id == zid } }
            selectedZoomID = nil
            return
        }
        let idx = project.segments.firstIndex { $0.id == id }
        edit { $0.segments.removeAll { $0.id == id } }
        if let idx, !project.segments.isEmpty {
            selectedID = project.segments[min(idx, project.segments.count - 1)].id
        } else {
            selectedID = nil
        }
    }

    func duplicateSelected() {
        guard let seg = selectedSegment else { return }
        var copy = seg
        copy.id = UUID()
        copy.zooms = seg.zooms.map { var z = $0; z.id = UUID(); return z }
        edit { p in
            if let i = p.segments.firstIndex(where: { $0.id == seg.id }) { p.segments.insert(copy, at: i + 1) }
        }
        selectedID = copy.id
    }

    func moveSelected(by delta: Int) {
        guard let id = selectedID, let i = project.segments.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < project.segments.count else { return }
        edit { $0.segments.swapAt(i, j) }
    }

    /// Reorder by dropping a clip whose centre lands at timeline time `t`.
    func move(_ id: UUID, toTimelinePosition t: Double) {
        guard let from = project.segments.firstIndex(where: { $0.id == id }) else { return }
        let others = placed.filter { $0.id != id }
        let to = others.filter { ($0.start + $0.end) / 2 < t }.count
        guard to != from else { return }
        edit { p in
            let s = p.segments.remove(at: from)
            p.segments.insert(s, at: min(to, p.segments.count))
        }
    }

    func setInToPlayhead() {
        guard let p = placedSegment(at: currentTime), p.id == selectedID ?? p.id else { return }
        let t = p.segment.sourceTime(atLocal: currentTime - p.start)
        selectedID = p.id
        updateSegment(p.id, coalesce: false) { $0.sourceStart = t }
    }

    func setOutToPlayhead() {
        guard let p = placedSegment(at: currentTime), p.id == selectedID ?? p.id else { return }
        let t = p.segment.sourceTime(atLocal: currentTime - p.start)
        selectedID = p.id
        updateSegment(p.id, coalesce: false) { $0.sourceEnd = t }
    }

    func addZoomAtPlayhead() {
        guard let p = placedSegment(at: currentTime) else { return }
        let local = currentTime - p.start
        let dur = min(2.5, max(0.5, (p.end - p.start) - local))
        let z = ZoomEffect(start: local, duration: dur)
        updateSegment(p.id, coalesce: false) { $0.zooms.append(z) }
        selectedID = p.id
        selectedZoomID = z.id
        frameEditor = FrameEditorRequest(segmentID: p.id, mode: .focus(z.id))
    }

    func editCropOfSelected() {
        guard let id = selectedID ?? placedSegment(at: currentTime)?.id else { return }
        selectedID = id
        frameEditor = FrameEditorRequest(segmentID: id, mode: .crop)
    }

    func applyCropToAll(_ crop: CropRect) {
        edit { p in for i in p.segments.indices { p.segments[i].crop = crop } }
    }

    // MARK: - Playback

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= timelineDuration - 0.05 { seek(0) }
            player.play()
        }
    }

    func seek(_ t: Double) {
        let t = min(max(0, t), timelineDuration)
        currentTime = t
        player.seek(to: cm(t), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stepFrame(_ n: Int) {
        player.pause()
        seek(currentTime + Double(n) / Double(project.fps))
    }

    private func projectChanged() {
        let l = TimelineLayout.layout(project.segments)
        placed = l.items
        timelineDuration = l.duration
        if let id = selectedID, !project.segments.contains(where: { $0.id == id }) { selectedID = nil }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.rebuildPlayer()
        }
    }

    private func rebuildPlayer() async {
        do {
            guard let built = try await CompositionBuilder.build(project, cache: cache) else {
                player.replaceCurrentItem(with: nil)
                return
            }
            if Task.isCancelled { return }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            let wasPlaying = isPlaying
            let t = min(currentTime, built.duration)
            player.replaceCurrentItem(with: item)
            await player.seek(to: cm(t), toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        } catch {
            errorMessage = "Could not build the timeline: \(error.localizedDescription)"
        }
    }

    // MARK: - Media

    func importPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addClip(url: url) }
    }

    func addClip(url: URL) {
        Task {
            do {
                let info = try await cache.info(for: url.path)
                guard info.video != nil else {
                    errorMessage = "\(url.lastPathComponent) has no video track."
                    return
                }
                sourceDurations[url.path] = info.duration
                let seg = Segment(name: url.deletingPathExtension().lastPathComponent,
                                  sourcePath: url.path, sourceStart: 0, sourceEnd: info.duration)
                edit { $0.segments.append(seg) }
                selectedID = seg.id
            } catch {
                errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func thumbnail(for seg: Segment) -> NSImage? {
        let key = "\(seg.sourcePath)#\(Int(seg.sourceStart * 4))"
        if let img = thumbnails[key] { return img }
        if pendingThumbs.insert(key).inserted {
            Task {
                if let cg = await frameImage(path: seg.sourcePath, time: seg.sourceStart + 0.05, maxSize: 240) {
                    thumbnails[key] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
        }
        return nil
    }

    func frameImage(path: String, time: Double, maxSize: CGFloat) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = cm(0.1)
        return try? await gen.image(at: cm(time)).image
    }

    // MARK: - Export

    func exportPanel(settings: VideoExportSettings) {
        guard !project.segments.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = (projectURL?.deletingPathExtension().lastPathComponent ?? "Mahmoud Export") + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await export(to: url, settings: settings) }
    }

    /// Output frame size for the current project (what the export will render).
    func outputSize() async -> CGSize {
        guard let first = project.segments.first,
              let info = try? await cache.info(for: first.sourcePath) else { return CGSize(width: 1920, height: 1080) }
        let o = info.orientedSize
        return project.preset.size(firstClip: CGSize(width: o.width * first.crop.w, height: o.height * first.crop.h))
    }

    func export(to url: URL, settings: VideoExportSettings) async {
        player.pause()
        do {
            guard let built = try await CompositionBuilder.build(project, cache: cache) else { return }
            exportProgress = 0
            try await VideoWriter.export(built, to: url, settings: settings, fps: project.fps) { p in
                Task { @MainActor [weak self] in
                    if let current = self?.exportProgress, p - current > 0.005 || p >= 1 { self?.exportProgress = p }
                }
            }
            exportProgress = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportProgress = nil
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - GIF export

    func gifPanel(settings: GIFSettings) {
        guard !project.segments.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = (projectURL?.deletingPathExtension().lastPathComponent ?? "Mahmoud Export") + ".gif"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await exportGIF(to: url, settings: settings) }
    }

    /// Time range the GIF covers: whole timeline, or only the selected clip.
    func gifRange(_ settings: GIFSettings) -> (start: Double, end: Double) {
        if settings.selectedClipOnly, let id = selectedID, let p = placed.first(where: { $0.id == id }) {
            return (p.start, p.end)
        }
        return (0, timelineDuration)
    }

    func exportGIF(to url: URL, settings: GIFSettings) async {
        player.pause()
        do {
            guard let built = try await CompositionBuilder.build(project, cache: cache) else { return }
            let range = gifRange(settings)
            let end = min(range.end, built.duration)
            let step = 1.0 / Double(settings.fps)
            let count = max(1, Int(((end - range.start) / step).rounded(.down)))
            let times = (0..<count).map { cm(range.start + Double($0) * step) }

            let gen = AVAssetImageGenerator(asset: built.composition)
            gen.videoComposition = built.videoComposition
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            let rs = built.videoComposition.renderSize
            let w = CGFloat(min(settings.width, Int(rs.width)))
            gen.maximumSize = CGSize(width: w, height: (w * rs.height / rs.width).rounded())

            try? FileManager.default.removeItem(at: url)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                             count, nil) else {
                errorMessage = "Could not create the GIF file."
                return
            }
            if settings.loop {
                CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
                                                        [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            }
            let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step,
                                                              kCGImagePropertyGIFUnclampedDelayTime: step]] as CFDictionary

            exportProgress = 0
            var done = 0
            var added = 0
            for await result in gen.images(for: times) {
                if let image = try? result.image {
                    CGImageDestinationAddImage(dest, image, frameProps)
                    added += 1
                }
                done += 1
                exportProgress = Double(done) / Double(count)
            }
            exportProgress = nil
            guard added > 0, CGImageDestinationFinalize(dest) else {
                errorMessage = "GIF export failed: no frames could be rendered."
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportProgress = nil
            errorMessage = "GIF export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Project files

    func newProject() {
        edit { $0 = Project() }
        projectURL = nil
        selectedID = nil
        seek(0)
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                let p = try JSONDecoder().decode(Project.self, from: data)
                for s in p.segments {
                    if let info = try? await cache.info(for: s.sourcePath) { sourceDurations[s.sourcePath] = info.duration }
                }
                edit { $0 = p }
                projectURL = url
                selectedID = nil
                seek(0)
            } catch {
                errorMessage = "Could not open project: \(error.localizedDescription)"
            }
        }
    }

    func saveProject(as: Bool = false) {
        var url = projectURL
        if url == nil || `as` {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Untitled.screencut.json"
            guard panel.runModal() == .OK, let u = panel.url else { return }
            url = u
        }
        guard let url else { return }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(project).write(to: url)
            projectURL = url
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}
