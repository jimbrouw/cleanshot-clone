import XCTest
@testable import CatchCore

final class TakeCaptionsTests: XCTestCase {
    func testTrimClipsAndShiftsCuesAndFormatsSRT() {
        let cues = [CaptionCue(start: 1, end: 3, text: "First"),
                    CaptionCue(start: 4, end: 6, text: "Second"),
                    CaptionCue(start: 7, end: 8, text: "Outside")]
        let trimmed = TakeCaptions.trimmed(cues, start: 2, end: 5)
        XCTAssertEqual(trimmed.map(\.start), [0, 2])
        XCTAssertEqual(trimmed.map(\.end), [1, 3])
        XCTAssertEqual(TakeCaptions.srt(trimmed), "1\n00:00:00,000 --> 00:00:01,000\nFirst\n\n2\n00:00:02,000 --> 00:00:03,000\nSecond\n")
    }
}
