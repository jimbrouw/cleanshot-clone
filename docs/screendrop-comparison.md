# Catch versus Screendrop

Source comparison as of 2026-11-16. Catch baseline: PR #2, ac0899d55f868946af284c0f49b6a83cb0a39c33.
This is a code/documentation comparison, not a live performance or reliability benchmark.

## Current advantages to validate with users

- Catch targets macOS 14; Screendrop's README requires macOS 26.4.
- Catch implements scrolling capture, OCR-to-speech, clipboard history, and Google Drive uploads. These are not documented in Screendrop's README; absence from its README is not proof of absence.
- Catch has an opt-in local Studio MCP bridge with a separate capture-session key and selected-take handoff. Agent integration alone is not a durable differentiator: Screendrop's tree also includes MCP settings.
- Catch already offers a speech-following teleprompter, hold-to-draw demo annotations, and portable script/edit-note handoffs. Validate the entire recording and playback workflow before marketing reliability.

## Where Screendrop leads

Its documented Studio workflow includes separate editable camera/screen masters, reconstructed cursor effects, automatic zooms, timeline editing, transcript-based cuts, and composed exports. Its companion Cloudflare Worker provides hosted playback, searchable transcripts, and timestamped comments. Catch currently has basic trimming and captions; its floating camera framing should not be presented as a separately editable camera track. Catch's loopback preview is local-only, while its Drive uploads provide external sharing.

Sources:
- https://github.com/fayazara/Screendrop/blob/main/README.md
- https://github.com/fayazara/Screendrop/blob/main/LICENSE
- https://github.com/jimbrouw/cleanshot-clone/pull/2

## Product recommendation

Focus Catch on "Show it once. Hand off something useful."

1. First wedge: software demos with private presenter notes, live callouts, reviewed captions, and a timestamped transcript that a colleague or editing agent can use immediately.
2. Next: export an evidence package containing the selected final video, matching transcript, script, and explicit edit notes. Preserve original media and the existing opt-in access boundaries.
3. Later: turn reviewed captures into illustrated guides or draft issue reports. Let users review generated claims before export. Browser logs and network context require an additional browser integration; they are not available from screen pixels alone.

Do not claim current support for generated guides, issue reports, automatic fixes, or separate-track camera editing.

## Adoption order

1. Searchable transcript and portable text/WebVTT exports (this change).
2. Robust non-destructive multi-cut editing with caption remapping.
3. Separate camera/audio masters, then cursor/zoom composition.
4. Optional hosted review with timestamped comments.

Screendrop's CC0 code can be reused commercially. Check dependencies and assets individually before importing them. Keep Catch's macOS 14 compatibility where practical. This change independently implements transcript workflow ideas; no upstream code or dependencies are copied and no fork is needed.

## Verification

Added XCTest cases cover transcript timecodes, edited timeline offsets, WebVTT timestamps, literal markup escaping, multiline cues, and empty exports.
Run `swift test` and `swift build` on macOS. In Review, expand Search and correct transcript, search for a spoken phrase, Play a result, correct it, clear the filter, and copy the full transcript. Export SRT and WebVTT and load them in a compatible player. Repeat on an edited copy to check timestamps.
The Linux implementation environment has no Swift toolchain or macOS frameworks; builds and playback are not verified here.
