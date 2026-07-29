# Highlights

Mark the good moments during a game; get the clips, not the game.

Tap the screen when something happens and the previous ~25 seconds — already recorded — become a
clip. No 90-minute video to scrub through afterwards.

Built for filming youth soccer from the sideline with a phone on a tripod, but nothing in it is
soccer-specific.

## The two ideas this is built on

**1. A rolling buffer saves editing time, not battery.** The camera and encoder run identically
whether you keep footage or throw it away. So rather than a fragile in-memory ring buffer, this
records continuously to short segment files, marks timestamps when you tap, and prunes what
nothing needs. If you tap late, the footage is still there. You can widen the window afterwards.
Nothing is lost to a buffer bug.

**2. Don't zoom during the game. Zoom afterwards.** Capture is 4K; a highlight you'll text to
someone is 1080p. Cropping a 1920×1080 window out of 3840×2160 is an *exact 2× zoom with zero
quality loss* — and you choose where that window sits after the game, when you already know where
your player was.

That second one is what makes the app usable by one person with a hand on a tripod. On the
sideline you only have to keep them somewhere in a wide frame; the tight framing happens later, at
a table, where nothing is moving.

## Using it

The app opens in **standby** — camera live so you can frame the shot, nothing being written.

- **Record** starts capture. Halftime? Stop, and start again after — each recording is its own
  session and previous clips stay intact.
- **Tap anywhere** to mark a moment. A Bluetooth clicker that sends a keyboard key works too.
- **Dim** drops screen brightness to near zero while still recording and still accepting taps.
- **Clips** lists what you marked. Open one to trim it, frame the crop, and save to Photos.

### Field notes

Things that are true regardless of the software:

- **Use the wide (1×) lens, not the telephoto.** Counterintuitive, but the tele has a smaller,
  worse sensor, and shooting tele throws away the crop latitude the whole approach depends on.
  The app always uses the wide camera for this reason.
- **A fluid-head tripod (~$40) beats any software.** A fluid pan head versus a friction ball head
  is the single biggest improvement to smooth panning.
- **Higher and further back is better.** It reduces the angular speed you have to track.
- **Take the case off and keep the phone out of direct sun.** 4K recording is genuinely demanding.
- **Guided Access** (Settings → Accessibility) stops an accidental swipe from backgrounding the
  app mid-game, which stops capture.
- ~13 GB/hour at 4K30. Retention keeps that bounded, but check free space before a tournament.

## Building

Requires Xcode 26+ and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The `.xcodeproj` is generated, not checked in.

```bash
xcodegen generate && open Highlights.xcodeproj
```

Set your own team in `project.yml` (`DEVELOPMENT_TEAM`) and change
`PRODUCT_BUNDLE_IDENTIFIER` — a bundle ID can only be claimed once.

**Real device only.** The Simulator has no camera; the app detects that and says so rather than
hanging.

The icon is generated rather than checked in as art:

```bash
swift Tools/GenerateIcon.swift
```

## Architecture

```
Sources/
  Capture/
    CaptureEngine.swift            State machine, thermal response, stall watchdog
    CaptureSessionController.swift AVCaptureSession, rotation, output attach/detach
    SegmentRecorder.swift          The AVAssetWriter. Non-isolated, single-queue discipline.
    SegmentStore.swift             Per-session segment store, retention, protection
    CaptureSettings.swift          Persisted user configuration
  Highlights/
    Highlight.swift                The mark model + persisted library
    ClipComposer.swift             Stitches segments into a correctly-timed asset
    CropPath.swift                 Time-varying crop window + the smoothing that makes it watchable
    HighlightExtractor.swift       Compose → crop → export → Photos
    SubjectTracker.swift           Offline Vision tracking to build a camera move
  Triggers/
    TriggerCoordinator.swift       Fan-in for all trigger sources, with debounce
    KeyCommandCatcher.swift        Bluetooth clickers that present as a keyboard
  UI/
    CaptureView.swift              The sideline screen
    SafeFrameOverlay.swift         Shows how much room you have to be wrong
    HighlightEditorView.swift      Trim, framing, auto-follow, export
    TrimBar.swift                  Two-handle trim control
    LibraryView.swift, SettingsView.swift, CameraPreview.swift
```

### Why one asset writer

`AVAssetWriter` runs in HLS segmenting mode, emitting an initialization segment plus periodic
independently-decodable fMP4 media segments from a single uninterrupted encode. The obvious
alternative — rotating a fresh writer every few seconds — drops frames at every handoff, and
overlapping two writers to hide the gap means two concurrent 4K encodes on a phone that is already
thermally marginal.

### Segments are self-contained

Each stored segment has the initialization header prepended **when it's written**. The header is
about a kilobyte, so every segment is a standalone, playable single-fragment fMP4 for almost
nothing — and opening a clip becomes pure metadata instead of copying tens of megabytes.

This was learned the hard way. Byte-concatenating fragments into one file produces a technically
valid stream that AVFoundation reads only *partially*: with no `sidx` index and no duration in the
movie header, it stops after the first fragment or two, so a 14-second clip arrived as 4 seconds.
`ClipComposer` now stitches the per-segment files with an `AVComposition`, whose duration is
explicit by construction.

### Timeline alignment

`AVAssetSegmentReport` timestamps arrive in the writer session's *source* time — absolute
presentation timestamps, tens of thousands of seconds since boot, not zero-based. Bookmarks are
stamped with session-relative elapsed time. `SegmentRecorder` anchors on the first segment's
reported time and expresses everything relative to it, which is correct whether the reports turn
out to be absolute or already-relative.

### Retention and protection

Unprotected segments older than the retention window are deleted as recording proceeds. Marking a
moment **pins** the segments it needs, repeatedly for a few seconds afterwards — the post-roll
hasn't been encoded yet at the instant you tap. Saving to Photos does *not* release them by
default: the exported file is cropped and flattened, so the retained footage is the only route back
to the full frame. Deleting a clip frees its footage.

Everything survives the app being killed, which matters because a hot phone at halftime shouldn't
cost you the first half.

### The crop is transform ramps, not a custom compositor

`AVMutableVideoCompositionLayerInstruction.setTransformRamp` expresses the moving crop window as a
series of affine transforms, keeping everything on AVFoundation's hardware-accelerated render path
with no per-frame callback into our code.

Export resolution falls out of the crop: the window is taken from the 4K frame at native pixels, so
uncropped is genuinely 4K and a 2× crop is exactly 1080p, neither one scaled.

## Debugging

Start-up and every fault are logged under a dedicated subsystem:

```bash
xcrun devicectl device process launch --device <udid> --console --terminate-existing com.danmason.highlights
```

Or filter by `subsystem == "com.danmason.highlights"` in Console.app.

## Not built yet

- Apple Watch trigger
- Filmstrip thumbnails along the trim bar
- Slow-motion beat on the moment of contact
- Sharing beyond saving to Photos
