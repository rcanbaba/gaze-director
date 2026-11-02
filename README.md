# Gaze Director

A macOS prototype that keeps your eyes on the camera while you read from the screen. While you read, it shows your eyes looking at the camera. Every few seconds it adds a short, natural-looking glance away. There is no machine-learning training involved: it uses Vision face landmarks, a classic gradient-based iris locator and a Metal warp of your own eye pixels.

![Synthetic eye through the warp: original, right, left, up, down, up-right](docs/warp-preview.png)

## How it works

```
Camera (AVCaptureSession, BGRA)
  → Vision face landmarks: eye contours + rough pupil
  → Iris centre per eye: gradient-based locator (Timm & Barth) in an eye-aligned crop, One Euro smoothing
  → Gaze director: is the (low-passed) gaze reading, i.e. inside the zone and closer to the
    reading centre than to the camera point? Blinking? Head turned?
       reading → target = camera point + tiny fixation shifts + a glance away every 2–3.5 s
       else    → let the real eyes through
  → Metal warp: shift each iris by (target − calibrated reading offset), lids follow on vertical moves
  → Preview (later: virtual camera for Teams / Meet)
```

- **No new pixels.** The warp moves your own pixels. The iris slides and the sclera compresses on one side and stretches on the other. Eye corners stay pinned. On vertical moves the upper lid follows the iris more than the lower lid does.
- **Behaviour matters more than pixels.** Glance timing is randomised. Glances move as fast saccades (about 50 ms), not slow slides. You glance away more often while talking (2–3.5 s apart) than while listening (4–7 s apart). Blinks pass through. When you really look away or turn your head, the effect lets go.
- **Calibrated to you.** You look at the camera lens once to record each iris's "eye contact" position. Then you read normally for 8 seconds, and the app learns the reading zone and the typical reading offset from where your eyes actually go.
- **Steady, not twitchy.** On a real 1080p webcam, Vision gives only six contour points per eye, and per-frame iris estimates jitter. So the warp mainly corrects by the fixed calibrated reading offset (medians over the calibration), and *Follow reading motion* (default 0.5) cancels half of the left-right reading sweep on top.
- **Vertical gaze from the eyelid.** The upper lid follows vertical gaze closely. When the eyes open noticeably wider while reading than while looking at the lens (the reading spot is higher), or narrower (lower), and that change is larger than the measured vertical iris shift, it sets the vertical correction. A *Strength* slider scales the whole offset for estimators that under-read it.
- **The warp follows the iris, not the contour.** Vision's six-point contour cuts through the iris on real faces, and clipping the warp to it held real moves to about 40% of the plan. The iris now shifts as a whole, the band around it stretches, and the contour only pins the eye corners. Moves are capped at 0.11 eye widths by default; beyond that the lash line near the eye corner starts to smear.
- **Iris source.** By default the iris is found by a gradient locator on an eye crop where bright spots are first removed by a grayscale opening. Without that step, a screen reflection inside a dark pupil made the locator jump between two places. On three recorded sessions the cleaned locator saw a consistent reading shift in both eyes, about 1.5–2.5× what Vision's pupil landmark reports. Vision's pupil (very steady, but its face-shape prior under-reads eye rotation) remains an option.

## Build and run

Requirements: macOS 14+, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open GazeDirector.xcodeproj
```

Run the `GazeDirector` scheme. The run configuration is Release because the per-frame iris search is unoptimised in Debug builds. Signing uses the team in `project.yml`; change `DEVELOPMENT_TEAM` to yours.

## Using it

1. Put the text you will read **at the top centre of the screen, right under the camera**, in a **narrow column**. This one setting matters more than any algorithm tweak: it keeps the needed correction to a few degrees, where the warp is hard to spot.
2. Click **Calibrate** and look straight into the lens. After 2 seconds a chime plays: read your text normally until the second chime (8 seconds). Doing only the camera step clears the reading zone and turns correction off; the badge on the preview says so.
3. Read. The gaze map shows the reading zone (blue), your real gaze (●) and where the eyes are being shown (○). The debug overlay draws the eye contours, the tracked iris and the target.

To judge the result, use **Record 15 s clip** and read normally. Watching the live preview while reading moves your gaze out of the reading zone, which switches the correction off. The clip saves original | corrected side by side to `~/Movies/GazeDirector` and opens it. A green square marks corrected frames.

Settings: talk mode (*I'm talking* / *I'm listening* / *Detect with microphone*), glances on/off, and max correction (in fractions of eye width; above roughly 0.16 the warp becomes noticeable).

## Virtual camera

`GazeCamera/` is a Core Media I/O camera extension embedded in the app. It exposes a **Gaze Director** camera with two streams. A sink stream receives the corrected frames from the app (scaled to 1280×720 BGRA, 30 fps). A source stream is what other apps read. While the app is not sending, the camera shows a placeholder.

1. Signing needs an Apple Developer account in Xcode (Settings → Accounts) for the team in `project.yml`. The system extension install entitlement requires a provisioning profile.
2. Build, copy `GazeDirector.app` to `/Applications` and open it from there.
3. Click **Install camera extension**, then approve it in System Settings → General → Login Items & Extensions → Camera Extensions.
4. Pick **Gaze Director** as the camera in FaceTime, Photo Booth, Teams, Zoom or the browser. Keep the app open; it does the processing.

## Gifts and banners

The sidebar plays gift animations and text banners over the outgoing video, so they show up in Photo Booth, FaceTime or a call. **⌃⌥1–9** trigger gifts 1–9 and **⌃⌥⇧1–9** trigger gifts 10–18 while another app is in front. These are Carbon hot keys, so no Accessibility permission is needed.

- **Format.** Gifts are side-by-side alpha videos: colour on the left half (premultiplied over black), the alpha mask as grey on the right half. This is the layout live-stream gift effects use, so gifts exported from a live-stream app work as they are.
- **Compositing.** Core Image composites the gift as `colour × min(1, 3·mask) + camera × (1 − mask)`, after cleaning the mask floor left by video compression:
  - The boosted weight keeps glows bright but drops the faint haze that renders leave where the mask is about zero.
  - `CIAdditionCompositing` also adds alpha, so alpha is reset to 1. With alpha 2, the gift area washed out.
- **Placement.** Portrait gifts are centred and fitted to the frame height. Landscape ones, such as the text banners, cover the whole frame.
- **Shipped content.** Four original demo gifts (hearts, confetti, stars, applause) and two sliding banners ("Thank you for your time 🙏", "Great to meet you 👋") ship in `GazeDirector/Resources/Gifts`. `Tools/GiftMaker` renders them.
- **Your own gifts.** Put them in `~/Movies/GazeDirector/Gifts`, then press **Reload**. They are not part of the repo.
- **Mirrored self-view.** Photo Booth, FaceTime and Teams show your own preview mirrored, so banner text reads backwards to you. The people you call see it the right way round, as does the before/after clip.

## Tools

- `GazeCore/` is a Swift package with all the testable logic: eye geometry, iris locator, One Euro filter, calibration, the director and the warp planner. Run its tests with `cd GazeCore && swift test`.
- `Tools/warp-preview.sh` renders a synthetic eye through the real shader and writes `Tools/out/warp-preview.png`.
- Calibration saves raw frames and measurements to `~/Library/Application Support/GazeDirector/Diagnostics` (sidebar toggle, local only).
  - `Tools/eye-probe.sh <frame.png>` draws the tracked contours and iris on a saved frame.
  - `Tools/out/warp-frame <camera-folder> <reading-folder> <frame.png> <out.png> [--gradient] [--strength 1.0] [--follow 0.5] [--max 0.11]` applies the full correction to a saved reading frame. It writes recorded | corrected | camera-look reference side by side. With `--gradient` it recalibrates from the saved frames with the gradient locator.
  - `Tools/out/replay [--vision] <camera-folder> <reading-folder>` (built like the other tools, from `Tools/Replay`) replays a calibration through the director and warp planner. It reports how often redirection is on and how much the warp jitters.
  - `Tools/out/estimators <camera-folder> <reading-folder>` compares Vision's pupil, the gradient locator and the reflection-cleaned gradient locator on a session's saved frames: jitter while looking at the lens, and the reading shift each one sees.

## Limitations

- The reading spot sets how much correction is needed. Text far from the lens (for example a screen corner) can need more than the 0.11 cap, so some sideways look remains. Keep the text at the top centre, under the camera.
- Glasses with reflections, strong side light and big head turns make tracking and the warp less reliable.
- The catchlight moves with the iris. At webcam resolution this is barely visible.
- It looks most convincing in a normal call tile. Full-screen high-resolution viewing shows more.

## Roadmap

- [x] CoreMediaIO Camera Extension, so Teams, Meet, Zoom, FaceTime and Photo Booth can pick "Gaze Director" as a camera.
- [ ] Zoomed eye view for tuning.
- [ ] Optional learned warp trained on your own calibration recordings.
