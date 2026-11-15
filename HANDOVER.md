# Catch Studio — reliable software demos

Implement a local workflow a presenter can use for a real software demo: record the screen and spoken narration reliably, draw a quick callout without interrupting the demo, then review and trim the take. Work in that order. Get a real playback result at each milestone before adding the next feature.

## Starting point

- Workspace: `/Users/jim/Developer/CleanShot clone`. Read the global Codex instructions and any project instructions before editing.
- Start from the Git revision containing this handoff and the teleprompter, permission and sharing fixes. Inspect `git status --short --branch` before editing to preserve any subsequent local work.
- `build/Catch-Hardened.app` is the most recent packaged baseline in the existing checkout. Builds are ignored by Git. Use the build commands below if starting from a fresh clone. Quit any running Catch copy before opening a new build and verify which bundle is running. The bundles share an app ID and are ad hoc signed. Keep existing macOS grants when they work.
- The previous baseline passed 22 tests. The recorder test uses `headlessSynthetic: true`; it proves fixture export and history insertion. It does not prove a real desktop recording, microphone audio, camera, pause timing, or overlay privacy. The speech matcher also passed fixture checks. The complete live Follow Script workflow has not been independently verified.
- Scope the first pass to Catch Studio on this Mac. Keep the app local. Preserve the hardened local preview behavior and existing screenshot workflows. Use the built-in camera or a known working source for the first proof; an iPhone Continuity Camera connection is a separate check.

## 1. Make the recorder trustworthy

Start in [LoomVideoStudio.swift](Sources/CatchCore/Recording/LoomVideoStudio.swift), especially `startRecording`, `startScreenCaptureKitRecording`, `appendSampleBuffer`, and `finalizeWriter`.

1. **Make start and stop honest.** A failed screen stream currently falls back to a synthetic writer, then the UI enters Recording. Finalization can also fabricate frames when a real take delivered none. Keep synthetic frames confined to the explicit test path. Surface concrete start, stream and writer errors in Studio. Show a successful export and add it to History only after a real take has usable video and the writer has completed. Handle Stop during Preparing and repeated Stop without stale sessions or false success. Keep any recoverable media from interrupted takes clearly labelled.
2. **Wire the mic into the MP4.** The existing mic toggle changes UI state; the current stream and writer route screen and system audio only. Use a supported capture path for the deployment targets. Verify mic-only recording with system audio off. When both sources are enabled, choose and test how they are combined or exposed in the file. Keep source timing aligned with video. If requested audio cannot start, tell the presenter before the take.
3. **Add a mic meter tied to the selected recording input.** Show enough signal before recording for the presenter to check the right mic. Confirm it agrees with the exported file. Avoid introducing a second microphone session if sharing the input is practical. Verify that the recorder and Follow Script can run together without one taking the mic from the other.
4. **Check pause/resume and privacy in playback.** The current pause path drops samples while the clock is paused, and the writer uses source timestamps. Verify the result has no freeze or audio gap equal to the paused time. Verify Catch's own output excludes the teleprompter when Hidden, including when it is opened or changed mid-take. If the app cannot apply the requested exclusion, make that visible before relying on it.

**Acceptance:** Record 15–30 seconds of a harmless demo with a visible action, live narration and system audio off. Pause for several seconds, resume, and stop. Open the actual MP4. Confirm screen motion, intelligible in-sync narration, pause behavior, and no hidden teleprompter in the file. Then run a short system-audio-only check and a both-sources check. Exercise a denied or failed screen start in a controlled run; no normal Recording state, fake success file or History entry should result. Note the hardware and exact permissions used.

## 2. Add the hold-to-draw layer

The first version is one pen and one shortcut. Hold to draw over the app on the recorded display. Release to give mouse input back immediately. Keep the ink briefly visible, then fade it. Add a clear action if necessary to recover cleanly during a take.

- Use a transparent AppKit panel. With the shortcut held, take pointer events for strokes; on release, switch to click-through even while the ink remains visible. Clean up on recording stop, cancel, or display change. A shortcut collision or missed release must leave the user a way back to normal input.
- [SelectionOverlayController.swift](Sources/CatchCore/Capture/SelectionOverlayController.swift) shows how Catch creates a screen overlay. [CatchAppRunner.swift](Sources/CatchCore/App/CatchAppRunner.swift) registers global shortcuts and currently listens for presses. Add release handling for this shortcut without changing the behavior of the existing shortcuts. [AnnotateWindowController.swift](Sources/CatchCore/Annotate/AnnotateWindowController.swift) has the screenshot pen implementation to borrow from where practical.
- Start with one display. Verify full-display and area recordings independently. Include the ink in Catch Studio's output while keeping the private presenter UI out. Verify both in the exported file.

**Acceptance:** Record about ten seconds. Hold the shortcut, circle a harmless button, release, and click the button immediately. The exported video shows the ink, the click takes effect on the first try, and the marks fade. Repeat with a cropped recording and confirm the ink lines up with what it points at. Stop during an annotation and confirm the next click goes to the underlying app.

## 3. Make the first edit quick

After a valid take, open a local playback view with start/end trim, **Export Copy**, and **Reveal in Finder**. Keep the source file. Use the finalized media URL and preserve the audio tracks and timing. Keep the original available if export fails or is cancelled. Check existing History and Quick Access behavior before extending it; the current stop path passes a video through an image-oriented result.

**Acceptance:** Record a clip with a clear intro and outro, trim both ends, and play the exported copy. Confirm the intended cut, retained narration and sync, and intact original. An export failure must report an error and leave the source playable.

## 4. Add a local MCP bridge

Build this after the recorder passes milestone 1. Put the companion launcher in `scripts/` and document how a local MCP client starts it. Use [MCP over stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#stdio) and a private local connection to the running Catch app. Make agent access opt-in within Catch and preserve the existing default for `catch://`.

1. **Load a teleprompter script.** Accept script text and optional edit notes as separate fields. Preserve line breaks and bracketed stage directions. Load the script into the running teleprompter and keep the notes with the take. Start reading or recording only on a separate command.
2. **Control capture and recording.** Expose a screenshot action and start, pause, resume, stop, and status for Studio. Use Catch's existing capture and recorder paths. Report permission failures and invalid state transitions. Return the finalized recording path after the writer succeeds.
3. **Hand off a finished recording for editing.** Let the editing agent retrieve an explicitly selected take with its local MP4 path, script, and edit notes. Save a portable handoff alongside the media or as an export folder for a human editor. Include timestamps only when Catch measured them. Keep the source intact and let the user select what leaves the Mac.

**Acceptance:** From a local MCP client, load a two-part script with a silent cue, capture a screenshot of a harmless screen, then start, pause, resume, and stop a short test recording. Play the returned MP4. Retrieve that take from an editing client and verify the file, script, and notes match. Check that a disabled bridge refuses commands and that unfinished or unselected takes are unavailable to the editing client.

## Later, after a real demo passes

Use the existing CueOS and RoughCut work if a first edit still takes too much time. [CueOS](https://github.com/jimbrouw/cueOS) has an Edit Map and Premiere review-marker prototype that can distinguish a fixture retake from a candidate. `/Users/jim/Developer/Roughcut/src/xmlCutHost.ts` has the separate XML path for creating a new editable Premiere sequence. The handoff between them and a real scripted take have yet to be proven. Hosted video links, comments, analytics, and a full whiteboard are outside this pass.

## Verification and delivery

```bash
swift test
git diff --check
swift build -c release
```

Keep the last usable app bundle. Package a separate preview using the layout and signing steps in [scripts/build-app.sh](scripts/build-app.sh); the script itself replaces `build/Catch.app`. Verify the new bundle's signature. Run the live acceptance checks from the packaged app. Inspect the exported tracks and duration with a media probe if available, and play the take to check the actual picture and sound.

Report the preview path, what was checked in playback, anything that still needs the user's hardware or participation, and the next action. Use the completion ladder: scoped → code complete → locally verified → integrated/live verified → production proven. Keep fixture results and live recording results separate.

## Next milestone — Share a recording through Google Drive

**Status — Scoped.** From **Review Take**, upload the finalized MP4 directly to the user's Google Drive and copy a viewer link. The account owner supplies the storage and Google Drive plays the video. Catch keeps the local recording. The first release shares the full recording and labels that explicitly beside the trim controls. Drive is the only provider in this milestone.

1. **Prove playback and set up Google.** Record a harmless 20-second demo with narration, play the local MP4, then upload it manually to a test Drive account. Open an **Anyone with the link** link in a signed-out browser and record when picture and sound become playable. In the Catch Google Cloud project, enable Drive API v3, configure the consent screen, create a Desktop app OAuth client and add a test account. Check the consent and verification requirements for distribution before release. [Desktop OAuth setup](https://developers.google.com/identity/protocols/oauth2/native-app)
2. **Connect the account.** Add **Connect Google Drive** and **Disconnect** in Recording settings. Open the system browser for sign-in and use PKCE with a loopback callback and state validation. Request only `drive.file` and use `about.get` to display the connected account. Store refresh credentials in macOS Keychain. Disconnect clears the connection and explains how to remove existing links in Drive. [Drive scope](https://developers.google.com/workspace/drive/api/guides/api-specific-auth) · [Account details](https://developers.google.com/workspace/drive/api/reference/rest/v3/about/get)
3. **Upload the selected take.** Add the Drive client under `Sources/CatchCore/Cloud/` and wire it into [Review Take](Sources/CatchCore/Recording/TakeReviewWindow.swift). Pass only the finalized MP4. Read bounded chunks from disk and use a resumable upload into My Drive. Show progress and allow a retry after interruption. Resume from the byte offset Drive reports. Allocate a Drive file ID before uploading and keep it with the attempt so a lost completion response or sharing retry can reuse the same file. [Resumable uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads) · [Pre-generated file IDs](https://developers.google.com/workspace/drive/api/guides/create-file)
4. **Make link access explicit.** **Upload and Copy Link** shows the account, filename, **Full recording**, and the choice of **Restricted** (default) or **Anyone with the link**. For the second choice, create a reader permission with search discovery disabled. Copy Drive's `webViewLink` after the upload and selected permission succeed. If the account blocks external sharing, report **Uploaded to Drive. Link sharing was blocked.** and offer **Open in Drive**. Show **Link copied. Drive may still be processing the video.** after success. [Drive permissions](https://developers.google.com/workspace/drive/api/reference/rest/v3/permissions) · [Video processing](https://support.google.com/drive/answer/2423694)
5. **Verify in a packaged preview.** Run the existing checks above. From the preview, connect the test account, record and upload a new demo, and play it with picture and sound in a signed-out browser. Confirm a Restricted link denies that viewer. Interrupt an upload and verify that retry creates only one file. Exercise a denied sharing request and confirm the local MP4 is still playable and the clipboard only changes on success. Record the playback result and any account limits before calling the feature live verified.

### Google Drive preview setup and verification

The preview's **Settings → Screen Recording → Connect Google Drive** asks for the downloaded Google Cloud **Desktop app** OAuth client JSON. Enable Drive API v3, configure the OAuth consent screen, and add the Google account as a test user while the app is in Testing. Keep the JSON private; Catch stores the client credentials and refresh token in the macOS Keychain. Sign in through the system browser. Disconnect removes Catch's saved credentials; it does not delete uploaded files or revoke links. Manage those in Drive.

The initial Drive preview uploaded the full source MP4. The captions preview below also allows an explicitly selected edited copy. Restricted is the default. Retry from the same unchanged file and connected account reuses the saved Drive file ID and upload session; if a session expires, retry again to start a new session with that ID. Google may need time to process a video after upload. These paths still require the live account, sharing, interrupted-transfer, and signed-out playback checks above before claiming live verification.

## Captions and review preview — 15 November 2026

**Status: partially implemented; fixture checks only.** `build/Catch-Captions-Preview.app` is a separate ad-hoc-signed preview. It starts successfully. It contains the Drive integration plus on-device Speech transcription when Review Take opens, editable timed caption cues, an SRT export, and a CC preview. Caption edits are stored in a JSON sidecar beside the video. The edited-copy export re-encodes the selected range and saves a trimmed, shifted caption sidecar; open the edited copy in Review to export its SRT. The source remains intact. Review shows local file readiness and offers a full-recording or edited-copy upload. Google Drive upload and processing remain separate from local save.

`swift test` passed 26 tests with one optional external-media fixture skipped; `swift build -c release`, `git diff --check`, and deep signature verification passed. The new cue clipping and SRT formatting test uses fixture data. No real narrated take, transcription, trimmed playback, microphone, actual Drive upload, captions in Drive, or signed-out playback was verified. Caption timing, accuracy, and the effects of re-encoding must be checked with a real recording before use. The present Review layout is an interim step, not the requested finished three-action flow. Redo a section, updating the existing Drive file, and click zoom have not been implemented.

**Next:** In the preview, connect a test Google Drive account using the Desktop OAuth client described above; record a three-section narrated walkthrough; grant Speech Recognition access if asked; review caption accuracy and trim playback. Upload an anyone-with-the-link copy, attach its SRT in Drive's Manage caption tracks, and test picture, sound, and selectable captions in a signed-out browser. Manually upload a revised picture and sound as a new version of the same Drive file, reattach captions, and check the original link signed out. Only then implement the same-link replacement workflow and verify it with another real take.
