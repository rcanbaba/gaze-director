# Gaze Director

A macOS prototype that keeps your eyes on the camera while you read from the screen. While you read, it shows your eyes looking at the camera. Every few seconds it adds a short, natural-looking glance away. There is no machine-learning training involved: it uses Vision face landmarks, a classic gradient-based iris locator and a Metal warp of your own eye pixels.

![Synthetic eye through the warp: original, right, left, up, down, up-right](docs/warp-preview.png)

## How it works

```
Camera (AVCaptureSession, BGRA)
  → Vision face landmarks: eye contours + rough pupil
  → Iris centre per eye: gradient-based locator (Timm & Barth) in an eye-aligned crop, One Euro smoothing
  → Gaze director: is the real gaze inside the reading zone? Blinking? Head turned?
       inside  → target = camera point + tiny fixation shifts + a glance away every 2–3.5 s
       outside → let the real eyes through
  → Metal warp: move each iris from where it is to its target, lids follow on vertical moves
  → Preview (later: virtual camera for Teams / Meet)
```

- **No new pixels.** The warp moves your own pixels. The iris slides and the sclera compresses on one side and stretches on the other. Eye corners stay pinned. On vertical moves the upper lid follows the iris more than the lower lid does.
- **Behaviour matters more than pixels.** Glance timing is randomised. Glances move as fast saccades (about 50 ms), not slow slides. You glance away more often while talking (2–3.5 s apart) than while listening (4–7 s apart). Blinks pass through. When you really look away or turn your head, the effect lets go.
- **Calibrated to you.** You look at the camera lens once to record each iris's "eye contact" position. Then you read normally for 8 seconds, and the app learns the reading zone from where your eyes actually go.

## Build and run

Requirements: macOS 14+, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open GazeDirector.xcodeproj
```

Run the `GazeDirector` scheme. The run configuration is Release because the per-frame iris search is unoptimised in Debug builds. Signing uses the team in `project.yml`; change `DEVELOPMENT_TEAM` to yours.

## Using it

1. Put the text you will read **at the top centre of the screen, right under the camera**, in a **narrow column**. This one setting matters more than any algorithm tweak: it keeps the needed correction to a few degrees, where the warp is hard to spot.
2. Click **1 · Look at the camera lens** and look straight into the lens for 2 seconds.
3. Click **2 · Read your text normally** and read for 8 seconds.
4. Read. The gaze map shows the reading zone (blue), your real gaze (●) and where the eyes are being shown (○). The debug overlay draws the eye contours, the tracked iris and the target.

Settings: talk mode (*I'm talking* / *I'm listening* / *Detect with microphone*), glances on/off, and max correction (in fractions of eye width; above roughly 0.16 the warp becomes noticeable).

## Tools

- `GazeCore/` is a Swift package with all the testable logic: eye geometry, iris locator, One Euro filter, calibration, the director and the warp planner. Run its tests with `cd GazeCore && swift test`.
- `Tools/warp-preview.sh` renders a synthetic eye through the real shader and writes `Tools/out/warp-preview.png`.

## Limitations

- Glasses with reflections, strong side light and big head turns make tracking and the warp less reliable.
- The catchlight moves with the iris. At webcam resolution this is barely visible.
- It looks most convincing in a normal call tile. Full-screen high-resolution viewing shows more.

## Roadmap

- [ ] CoreMediaIO Camera Extension, so Teams, Meet, Zoom and FaceTime can pick "Gaze Director" as a camera.
- [ ] Zoomed eye view for tuning.
- [ ] Optional learned warp trained on your own calibration recordings.
