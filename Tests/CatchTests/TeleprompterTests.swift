import AppKit
import XCTest
@testable import CatchCore

final class TeleprompterTests: XCTestCase {
    func testFinalSingleWordReachesStageCueWithoutMoreSpeech() {
        let script = "Let me show you how it works.\n\n[OPEN THE MENU.]\nHere is the menu."
        let text = script as NSString
        var matcher = TeleprompterScriptMatcher(script: script)
        XCTAssertEqual(matcher.advance(with: "let me show you how it"), text.range(of: "works").location)
        XCTAssertEqual(matcher.nextSpokenWord, text.range(of: "works"))
        XCTAssertNil(matcher.advance(with: "menu", isFinal: true), "A later word alone must not skip ahead")
        XCTAssertNil(matcher.advance(with: "works"), "Wait for confirmation on an isolated partial")
        XCTAssertEqual(matcher.advance(with: "works", isFinal: true), text.range(of: "[OPEN").location)
        XCTAssertEqual(matcher.nextSpokenWord, text.range(of: "Here"))
    }

    func testVoiceScrollCrossesTheBlankLineBeforeACueInSilence() {
        let script = """
        Let me show you how it works.

        **[PAUSE. OPEN THE CATCH MENU.]**

        Here is the menu.
        """
        let controller = TeleprompterController()
        controller.scriptText = script
        controller.selectScrollMode(.voice)
        controller.scriptLayout.update(script: script, fontSize: 38, width: 448)
        guard let cue = controller.scriptLayout.stageDirections.first else {
            return XCTFail("Expected the pasted Markdown cue to be recognised")
        }
        XCTAssertLessThan(cue.approach, cue.start)
        controller.isPlaying = true
        let spoken = (script as NSString).range(of: "works").location
        let spokenProgress = controller.scriptLayout.progress(for: spoken)
        controller.scrollProgress = spokenProgress
        controller.advanceScroll(by: 0.1)
        XCTAssertEqual(controller.scrollProgress, spokenProgress, "Silence on spoken text should still hold")

        controller.scrollProgress = (cue.approach + cue.start) / 2
        controller.advanceScroll(by: 0.1)
        XCTAssertGreaterThan(controller.scrollProgress, cue.start)
        XCTAssertEqual(controller.voiceStatus, .stageDirection)
        controller.advanceScroll(by: 20)
        XCTAssertEqual(controller.scrollProgress, cue.end)
        XCTAssertEqual(controller.voiceStatus, .waiting)
        controller.advanceScroll(by: 0.1)
        XCTAssertEqual(controller.scrollProgress, cue.end)
        controller.pause()
    }

    func testSilentStageDirectionsScrollInBothVoiceModesAndStopAtDialogue() {
        let script = """
        **[OPEN THE CAPTURE MENU AND DRAG AROUND THE TOP LEFT CORNER OF THE WINDOW.]**

        [HOLD ON THE RESULT.]
        Here is the capture.
        This extra line makes any overshoot visible.
        A spoken sentence with [an aside] should stay a spoken sentence.
        """
        for mode in [TeleprompterController.ScrollMode.voice, .followScript] {
            let controller = TeleprompterController()
            controller.scriptText = script
            controller.selectScrollMode(mode)
            controller.wordsPerMinute = 120
            controller.scriptLayout.update(script: script, fontSize: 22, width: 220)
            let directions = controller.scriptLayout.stageDirections
            XCTAssertEqual(directions.count, 2)
            guard directions.count == 2 else { return }
            let dialogue = (script as NSString).range(of: "Here is the capture").location
            let stop = controller.scriptLayout.progress(for: dialogue)
            XCTAssertGreaterThan(stop, directions[0].end)

            // Exercise playback ticks without claiming the microphone.
            controller.isPlaying = true
            controller.advanceScroll(by: 1)
            XCTAssertEqual(controller.voiceStatus, .stageDirection)
            XCTAssertGreaterThan(controller.scrollProgress, 0)
            XCTAssertLessThan(controller.scrollProgress, directions[0].end)
            controller.advanceScroll(by: 20)
            controller.advanceScroll(by: 20)
            XCTAssertEqual(controller.scrollProgress, stop, accuracy: 0.0001)
            XCTAssertEqual(controller.voiceStatus, .waiting)
            controller.advanceScroll(by: 20)
            XCTAssertEqual(controller.scrollProgress, stop, accuracy: 0.0001)
            controller.pause()
        }
    }

    func testCueBeforeFinalSpokenLineKeepsListening() {
        let script = "[KEEP THE IMAGE VISIBLE.]\nThanks for watching."
        let controller = TeleprompterController()
        controller.scriptText = script
        controller.selectScrollMode(.followScript)
        controller.scriptLayout.update(script: script, fontSize: 22, width: 472)
        controller.isPlaying = true
        controller.advanceScroll(by: 20)
        XCTAssertEqual(controller.scrollProgress, 1)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.voiceStatus, .waiting)
        controller.pause()
    }

    func testScriptHoldsOnStageDirectionAndResumesOnSpokenLine() {
        let script = """
        Hi, I’m Jim and this is Catch.
        [OPEN THE CAPTURE MENU]
        Choose Capture Area to select a window.
        The thumbnail appears in the corner.
        """
        let text = script as NSString
        var matcher = TeleprompterScriptMatcher(script: script)

        XCTAssertEqual(matcher.advance(with: "Hi I'm Jim and this is Catch"), text.range(of: "[OPEN").location)
        XCTAssertNil(matcher.advance(with: "Open the capture menu"))
        XCTAssertNil(matcher.advance(with: "Just give me a moment"))
        XCTAssertEqual(matcher.advance(with: "Choose Capture Area"), text.range(of: "to select").location)
    }

    func testSkipNeedsContextAndAmbiguousRepeatsHold() {
        let script = """
        Welcome to the first part of this demo.
        Here we introduce the screenshot editor.
        Now open the export options to finish.
        The second part starts immediately below.
        Now open the export options once more.
        """
        let text = script as NSString
        var matcher = TeleprompterScriptMatcher(script: script)

        XCTAssertNil(matcher.advance(with: "options"))
        XCTAssertNil(matcher.advance(with: "now open the export options"))
        XCTAssertEqual(matcher.advance(with: "now open the export options to finish"),
                       text.range(of: "The second").location)
    }

    func testRewindUsesWrappedLinesAndCanRestartMatching() {
        let script = (1...10).map { "Line \($0) has enough words to wrap here." }.joined(separator: "\n")
        let layout = TeleprompterTextLayout()
        layout.update(script: script, fontSize: 22, width: 220)
        let anchor = (script as NSString).range(of: "Line 8").location
        let start = layout.position(progress: 0, anchor: anchor)
        XCTAssertGreaterThan(start, 0)
        XCTAssertGreaterThan(layout.position(progress: 1, anchor: nil), start)
        let rewind = layout.rewind(progress: 0, anchor: anchor)
        let restart = layout.character(at: rewind)
        XCTAssertLessThan(restart, anchor)
        XCTAssertGreaterThanOrEqual(restart, (script as NSString).range(of: "Line 6").location)
        var matcher = TeleprompterScriptMatcher(script: script, at: restart)
        XCTAssertNotNil(matcher.advance(with: "line 7 has enough words"))
    }
}
