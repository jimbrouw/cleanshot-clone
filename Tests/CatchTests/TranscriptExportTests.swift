import XCTest
@testable import CatchCore

final class TranscriptExportTests: XCTestCase {
    func testTimestampedTranscriptPreservesOrderAndTrimsText() {
        let cues = [CaptionCue(start: 65.9, end: 68, text: "  Open settings  "),
                    CaptionCue(start: 3661, end: 3663, text: "Save changes")]
        XCTAssertEqual(TakeCaptions.transcript(cues), "[00:01:05] Open settings\n[01:01:01] Save changes")
        XCTAssertEqual(TakeCaptions.transcript([]), "")
    }

    func testWebVTTUsesDotTimestampsWithoutChangingSpokenCommas() {
        let cues = [CaptionCue(start: 1.25, end: 3.5, text: "Hello, <world> & friends")]
        XCTAssertEqual(TakeCaptions.webVTT(cues),
                       "WEBVTT\n\n1\n00:00:01.250 --> 00:00:03.500\nHello, &lt;world&gt; &amp; friends\n")
    }

    func testWebVTTKeepsMultilineTextWithinOneCue() {
        let cues = [CaptionCue(start: 0, end: 2, text: "First\n\nSecond")]
        XCTAssertEqual(TakeCaptions.webVTT(cues), "WEBVTT\n\n1\n00:00:00.000 --> 00:00:02.000\nFirst Second\n")
        XCTAssertEqual(TakeCaptions.webVTT([]), "WEBVTT\n\n")
    }

    func testTrimmedTranscriptUsesEditedTimeline() {
        let cues = [CaptionCue(start: 5, end: 8, text: "Keep this"),
                    CaptionCue(start: 10, end: 12, text: "Remove this")]
        let trimmed = TakeCaptions.trimmed(cues, start: 6, end: 9)
        XCTAssertEqual(TakeCaptions.transcript(trimmed), "[00:00:00] Keep this")
        XCTAssertTrue(TakeCaptions.webVTT(trimmed).contains("00:00:00.000 --> 00:00:02.000"))
    }
}
