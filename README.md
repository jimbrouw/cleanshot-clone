# Catch (macOS Native Swift)

A native macOS screen capture, annotation, background framing, scrolling capture, on-device OCR, and pinned-screenshot suite built in Swift (AppKit, SwiftUI, ScreenCaptureKit, Vision, CoreImage, SQLite3).

## Implemented Features (Phases 1–3)

- **All-In-One HUD & Capture Modes**: Area, Previous Area, Fullscreen, Window (wallpaper/custom color padding with shadow, or `Shift` for transparent PNG), Self-Timer (`5s`), Crosshair Mode, Magnifier loupe, Freeze Screen, Desktop Icon Hider, sRGB conversion, `1x` Retina scaling, `@2x` suffixing, and `1px` border.
- **Scrolling Capture**: Interactive & `autoscroll` vertical frame capture with sticky-header exclusion and frame stitching (`VNTranslationalImageRegistrationRequest` + row-signature matching).
- **Quick Access Overlay**: Floating corner thumbnails (`Left`/`Right`), drag-and-drop into any app, all 10 quick actions (`Copy`, `Save`, `Annotate`, `Pin to the Screen`, `Upload to Cloud`, `Quick Look`, `Show in Finder`, `Open With...`, `Open in Mail...`, `Temporarily Hide`, `Close`), auto-close timer, and `Restore Last Capture`.
- **Annotate Editor & Background Tool**:
  - 13 tools: Select, Crop & Resize (rotate/flip), Arrow (4 styles + `Option` invert), Rectangle, Filled Rectangle, Ellipse, Line, Pencil (auto-smoothing), Highlighter, Text (7 styles: `Standard`, `Rounded Boxed`, `Rounded`, `Monospaced`, `Monospaced Boxed`, `Outlined`, `Boxed`), Counter (`1, 2, 3...`), Spotlight, Pixelate (with block randomization), and Blur (`Smooth` & `Secure`).
  - Eyedropper Color Picker (`Hex`, `RGB`, `Alpha`, `+ Add to My Colors`), Auto-Expand Canvas, Multi-Image Combine via drag-and-drop, and `"Drag me"` titlebar export.
  - Background Tool with 20 built-in gradients/wallpapers, blurred/plain/custom image backdrops, padding, corner radius, shadow, aspect ratios, Auto-Balance Content, and Brand Presets.
  - Editable `.catch` project bundle format (`base.png`, `preview.png`, `project.json`).
- **On-Device Text Recognition (OCR) & QR Codes**: Apple `Vision` (`VNRecognizeTextRequest` + `VNDetectBarcodesRequest`) with line-break and link detection.
- **Pinned Screenshots**: Always-on-top floating reference windows with opacity slider, `1px` arrow-key nudging, and click-through **Lock Mode**.
- **Capture History**: SQLite-backed history browser (`All | Screenshots | Videos | GIFs`), search, retention pruning, and one-click restore.
- **Local Sharing**: Copies a preview link that works from this Mac until Catch quits. The viewer listens on loopback and serves read-only previews.
- **10-Tab Settings & Custom Filename Builder**: All 13 tokens (`%y`, `%m`, `%n`, `%d`, `%w`, `%t`, `%a`, `%H`, `%M`, `%S`, `%p`, `%r`, `%i`), UTC toggle, and illegal-character sanitization.
- **URL Scheme API (`catch://`)**: Off by default. Enable it in Advanced settings only if you use URL automation. Websites and other apps can invoke commands while this setting is on.
- **Clipboard monitoring**: Off by default. Enable it in Clipboard settings to start collecting clipboard history.

## Build, Test & Package

```bash
swift build
swift test
bash scripts/build-app.sh
open build/Catch.app
```

### Local Catch Studio MCP bridge (experimental)

The bridge starts disabled each time Catch launches. In **Settings → Recording**, enable **Allow local MCP access**, then configure a local MCP client to launch this executable over stdio:

```json
{
  "mcpServers": {
    "catch-studio": {
      "command": "/usr/bin/python3",
      "args": ["/Users/jim/Developer/CleanShot clone/scripts/catch-studio-mcp.py"]
    }
  }
}
```

The adapter uses a private Unix socket. A client without a capture key can call only `selected_take`. In **Settings → Recording**, choose **Select finished take for editing…** to grant local clients access to one playable take and its notes. Use **Clear Selection** to revoke access through Catch.

For capture control, choose **Start Agent Capture Session** and use **Copy Capture Session Key**. Supply the key as `CATCH_CAPTURE_KEY` in the trusted client's process environment, then start or reconnect the MCP client. The key grants `load_script`, `screenshot`, `start`, `pause`, `resume`, `stop`, and `status`. End the session from Settings or Catch's menu to revoke the key. A recording already in progress can still be stopped in Studio. Local clients running as your macOS user can read a take you select while the bridge is enabled.

`load_script` accepts `script` and optional `edit_notes` separately. Turn on **Save script and edit notes with next take** before recording to save a matching `.handoff.json`. The option applies to one take. Legacy sidecars can be read by a human editor. Catch requires a new sidecar with media identity to share through MCP. The MP4 and sidecar can also be copied together for a human editor.

Open the hidden teleprompter before starting a take. Catch locks the privacy setting during the take and reports a failed start if it cannot build the required window exclusions.

Choose **Camera** and **Microphone** directly in Catch Studio or in **Settings → Recording**. Catch remembers the device choices for future takes. **System Default** follows macOS when the device is opened. **Check mic** uses the selected recording input and stops when recording or voice scrolling starts. The teleprompter's voice modes use the Mac's default input.

During an active recording, hold **Option-Shift-Command-D** to draw, release to return pointer input, and use **Clear Ink** to clear the layer. Marks fade after release. The review window exports a new file; passthrough trim points may move to video keyframes, so check the copy.

These features are experimental: microphone recording, pause timing, prompter exclusion, hold-to-draw, trim, and the end-to-end bridge require live recording and playback verification. The default `catch://` setting is independent of the bridge.

## Transcript handoff

In a finished take’s Review window, expand **Search and correct transcript** to find spoken text and play a matching caption. Corrections stay editable. **Copy Transcript** copies the full recording’s timestamped transcript, including when a search filter is active. **Export Captions** offers SubRip (`.srt`) and WebVTT (`.vtt`). Review an edited copy to export captions on its trimmed timeline.
