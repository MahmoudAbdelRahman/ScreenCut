# Mahmoud

The app is called **Mahmoud** (this repository and the source folder are still named ScreenCut).


A small, free, native macOS screen recorder and editor. No accounts, no watermark, no paid tier.
Built only on Apple frameworks (ScreenCaptureKit, AVFoundation, Core Image, SwiftUI). Needs macOS 15+.

## Download

Get `Mahmoud.zip` from the [latest release](https://github.com/MahmoudAbdelRahman/ScreenCut/releases/latest).
Works on Apple silicon and Intel Macs with macOS 15 (Sequoia) or newer.

1. Unzip and drag Mahmoud to Applications.
2. First launch: right-click > Open > Open (the app is not notarized by Apple).
   If it is still blocked: System Settings > Privacy & Security > Open Anyway.

## Build and run

```
./build.sh
open build/Mahmoud.app
```

To keep it in your Applications folder: `cp -R build/Mahmoud.app ~/Applications/`

First recording: macOS asks for Screen Recording permission (System Settings > Privacy & Security >
Screen & System Audio Recording). The app is signed ad hoc, so after a rebuild macOS may ask again.

## What it does (v0.1)

- **Record** a display, window or app via the system picker, with system audio, microphone (optional) and cursor.
  Files go to `~/Movies/Mahmoud/`. A menu bar item shows the time and stops recording.
- **Timeline**: split (⌘B), trim by dragging the yellow edges or with "Set In/Out to playhead",
  drag clips to reorder, duplicate, delete, undo/redo.
- **Speed** per clip (0.25× to 16×, pitch kept), **volume** per clip.
- **Crop** per clip with aspect presets (free, original, 16:9, 9:16, 1:1, 4:3), "apply to all".
- **Transitions** between clips: crossfade, dip to black, slide left/up, wipe, zoom blend,
  each with duration and an easing curve. On the first clip it fades in from black.
- **Zoom and pan** (the "screen recording zoom"): pick a focus point, zoom level, length,
  ramp time and easing (linear, ease in/out, smooth, overshoot).
- **Export** MP4 (⌘E) in H.264 or HEVC with High / Balanced / Small quality and a size estimate. Output size: same as clip, 1080p, 720p, vertical 9:16, square.
- **Animated GIF** export (⌥⌘G): width, frame rate, whole video or selected clip, loop.
- Projects save as JSON (⌘S); they reference the original video files.

## Code map

- `Model.swift` — project data, easing curves, timeline layout
- `CompositionBuilder.swift` — turns the project into an AVComposition (two alternating tracks so transitions can overlap)
- `Rendering.swift` — custom video compositor: crop, fit, zoom, transitions per frame with Core Image
- `Recorder.swift` — ScreenCaptureKit recording
- `EditorModel.swift` — edits, undo, playback, export
- Views: `ContentView`, `TimelineView`, `InspectorView`, `FrameEditorSheet`

Developer check (renders a test edit without the UI):
`build/Mahmoud.app/Contents/MacOS/Mahmoud --selftest in.mov out.mp4`

## Ideas for next versions

Text titles, auto-zoom following clicks, webcam bubble, blur/redact boxes, waveform in the timeline,
keyframed crop, fade-out at end, countdown before recording.

## License

MIT. See LICENSE.
