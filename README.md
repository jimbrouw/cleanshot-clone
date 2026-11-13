# CleanShot Clone (macOS Native Swift)

A native macOS screen capture, annotation, background framing, scrolling capture, on-device OCR, and pinned-screenshot suite built in Swift (AppKit, SwiftUI, ScreenCaptureKit, Vision, CoreImage, SQLite3).

## Implemented Features (Phases 1–3)

- **All-In-One HUD & Capture Modes**: Area, Previous Area, Fullscreen, Window (wallpaper/custom color padding with shadow, or `Shift` for transparent PNG), Self-Timer (`5s`), Crosshair Mode, Magnifier loupe, Freeze Screen, Desktop Icon Hider, sRGB conversion, `1x` Retina scaling, `@2x` suffixing, and `1px` border.
- **Scrolling Capture**: Interactive & `autoscroll` vertical frame capture with sticky-header exclusion and frame stitching (`VNTranslationalImageRegistrationRequest` + row-signature matching).
- **Quick Access Overlay**: Floating corner thumbnails (`Left`/`Right`), drag-and-drop into any app, all 10 quick actions (`Copy`, `Save`, `Annotate`, `Pin to the Screen`, `Upload to Cloud`, `Quick Look`, `Show in Finder`, `Open With...`, `Open in Mail...`, `Temporarily Hide`, `Close`), auto-close timer, and `Restore Last Capture`.
- **Annotate Editor & Background Tool**:
  - 13 tools: Select, Crop & Resize (rotate/flip), Arrow (4 styles + `Option` invert), Rectangle, Filled Rectangle, Ellipse, Line, Pencil (auto-smoothing), Highlighter, Text (7 styles: `Standard`, `Rounded Boxed`, `Rounded`, `Monospaced`, `Monospaced Boxed`, `Outlined`, `Boxed`), Counter (`1, 2, 3...`), Spotlight, Pixelate (with block randomization), and Blur (`Smooth` & `Secure`).
  - Eyedropper Color Picker (`Hex`, `RGB`, `Alpha`, `+ Add to My Colors`), Auto-Expand Canvas, Multi-Image Combine via drag-and-drop, and `"Drag me"` titlebar export.
  - Background Tool with 20 built-in gradients/wallpapers, blurred/plain/custom image backdrops, padding, corner radius, shadow, aspect ratios, Auto-Balance Content, and Brand Presets.
  - Editable `.cleanshot` project bundle format (`base.png`, `preview.png`, `project.json`).
- **On-Device Text Recognition (OCR) & QR Codes**: Apple `Vision` (`VNRecognizeTextRequest` + `VNDetectBarcodesRequest`) with line-break and link detection.
- **Pinned Screenshots**: Always-on-top floating reference windows with opacity slider, `1px` arrow-key nudging, and click-through **Lock Mode**.
- **Capture History**: SQLite-backed history browser (`All | Screenshots | Videos | GIFs`), search, retention pruning, and one-click restore.
- **Cloud Share & Comments Server**: One-click upload with clipboard link copy and local HTTP share viewer supporting spatial comments.
- **10-Tab Settings & Custom Filename Builder**: All 13 tokens (`%y`, `%m`, `%n`, `%d`, `%w`, `%t`, `%a`, `%H`, `%M`, `%S`, `%p`, `%r`, `%i`), UTC toggle, and illegal-character sanitization.
- **URL Scheme API (`cleanshot://` / `cleanshotclone://`)**: All 19 documented commands (`all-in-one`, `capture-area`, `capture-previous-area`, `capture-fullscreen`, `capture-window`, `self-timer`, `scrolling-capture`, `pin`, `record-screen`, `capture-text`, `open-annotate`, `open-from-clipboard`, `toggle-desktop-icons`, `hide-desktop-icons`, `show-desktop-icons`, `add-quick-access-overlay`, `open-history`, `restore-recently-closed`, `open-settings`).

## Build, Test & Package

```bash
swift build
swift test
bash scripts/build-app.sh
open build/CleanShotClone.app
```
