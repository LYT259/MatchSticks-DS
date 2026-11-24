# Natural Controller Motion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace pasted bitmap motion with calibrated, textured three-dimensional thumbsticks and a true 3D flight-stick assembly, and remove Direwolf 4's low-resolution artifacts without changing input mappings.

**Architecture:** Preserve `GamepadArtworkSpec` and the existing input/control overlays. Add a pure motion model, SceneKit-backed component views, and explicit alpha holes behind real well geometry. Use SceneKit throughout, with no new package dependency.

**Tech Stack:** Swift 5 language mode, SwiftUI, AppKit, SceneKit, CoreGraphics, existing custom UI test runner, macOS 14+, full Xcode toolchain.

## Global Constraints

- ADR `docs/decisions/0002-natural-controller-motion.md` is authoritative.
- Do not change `GamepadLayout`, HID values, robot packets, safety gates, or update behavior.
- No third-party graphics dependency and no fabricated official asset attribution.
- Preserve reference coordinates and existing 7° flight pitch/roll and 16° twist.
- Do not use raster upscaling, neighboring-pixel cloning, sharpening, or a translated cap image as the fix.
- Validate real rendered output for every supported skin, then run all standard checks and deliver the merged app.

---

### Task 1: Calibrated motion and hole masking

**Files:**
- Create: `Sources/MatchSticksDS/Views/GamepadArtwork/ThumbstickMotion.swift`
- Modify: `Sources/MatchSticksDS/Views/GamepadArtwork/GamepadArtwork.swift`
- Create: `Tests/MatchSticksDSUITests/ThumbstickMotionTests.swift`
- Modify: `scripts/test-ui.sh`

**Interfaces:**
- Produces: `ThumbstickMotion.pose(well:cap:state:) -> ThumbstickPose`, with `pivot`, `tiltX`, `tiltY`, `travel`, and `capSize` fields.
- Produces: `GamepadArtworkImageSource.imageMaskingStickCaps(_:capRegions:) -> CGImage?`, preserving pixels outside the mask and clearing alpha inside it.

- [x] **Step 1: Write failing behavior tests**

```swift
let neutral = ThumbstickMotion.pose(well: well, cap: cap, state: .init(x: 0, yUp: 0, pressed: false))
check(neutral.pivot == CGPoint(x: well.midX, y: well.midY) && neutral.tiltX == 0 && neutral.tiltY == 0, "neutral fixes the well pivot")
let right = ThumbstickMotion.pose(well: well, cap: cap, state: .init(x: 1, yUp: 0, pressed: false))
check(right.tiltY > 0 && right.pivot == neutral.pivot, "right tilt rotates around the well, not a bitmap offset")
let invalid = ThumbstickMotion.pose(well: well, cap: cap, state: .init(x: .nan, yUp: .infinity, pressed: false))
check(invalid == neutral, "invalid axes recenter safely")
let masked = GamepadArtworkImageSource.imageMaskingStickCaps(source, capRegions: [cap])
check(alpha(masked, at: capCenter) == 0 && rgba(masked, at: outside) == originalOutside, "mask clears only the old cap; no cloned pixels")
```

- [x] **Step 2: Run the UI suite and confirm missing API failures**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-ui.sh`
Expected: compilation fails because `ThumbstickMotion` and `imageMaskingStickCaps` do not exist.

- [x] **Step 3: Implement explicit clamped pose math and alpha-only masking**

Revision during implementation (verified at native resolution): the tilt angle is the physical gate limit of a thumbstick module, 20 degrees at full deflection, independent of the well/cap difference; the earlier `asin(travel / capRadius)` derived 17-50 degrees and laid the stick flat. The pivot sits in front of and below the cap centre (towards the user) inside the well, and the stick leans 20 degrees away from the viewer at rest, for every skin and both sticks. Normalise diagonal input to the circular gate. Clear cap regions with `CGBlendMode.clear`; never sample replacement pixels.

- [x] **Step 4: Verify and commit**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-ui.sh`
Expected: `0 failures`.
Commit: `fix: calibrate three-dimensional thumbstick motion`.

### Task 2: Textured 3D thumbsticks for all gamepads

**Files:**
- Create: `Sources/MatchSticksDS/Views/GamepadArtwork/ThumbstickSceneView.swift`
- Modify: `Sources/MatchSticksDS/Views/GamepadArtwork/GamepadArtworkOverlay.swift`
- Modify: `Tests/MatchSticksDSUITests/GamepadRenderingTests.swift`
- Modify: `Tests/MatchSticksDSUITests/GamepadArtworkTests.swift`

**Interfaces:**
- Consumes: Task 1's `ThumbstickPose` and alpha-masked body.
- Produces: `ThumbstickSceneView.update(spec:region:state:container:sourceImage:)`, `sceneView.snapshot()`.

- [x] **Step 1: Add failing geometry and rendered-scene checks**

Assert that the scene has separate well, shaft, cap and pressed-ring nodes; neutral Euler angles are zero; positive X rotates about Y; positive Y-up rotates oppositely about X; the pivot's world position does not change; cap top UVs reference the original texture. Render F310 and Direwolf 4 at neutral and full deflection and assert that side geometry becomes visible without changing the pivot.

- [x] **Step 2: Run tests and confirm failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-ui.sh`
Expected: missing `ThumbstickSceneView` or a missing real-node failure.

- [x] **Step 3: Implement the SceneKit component**

Create an orthographic scene with a textured cap mesh, side walls, shaft and recessed well. Attach the assembly to the fixed pivot from Task 1. Apply `tiltX` and `tiltY` to the pivot, not a SwiftUI image offset. Keep the original texture for cap top UVs and use opaque geometry rather than a circle mask. Attach pressed highlighting to the cap. Cache geometry and update only on state changes; never install a timer.

- [x] **Step 4: Integrate all ordinary skins and render comparisons**

Use the component for F310/generic, Direwolf 4, DualShock 4, DualSense and Xbox Series. Remove `NativeStickCap` and `stickCapOffset`. Render neutral, left, right, up, down, diagonal and pressed states for each. Compare against the recordings and verify no static cap or repaired patch appears.

- [x] **Step 5: Verify and commit**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-ui.sh`
Expected: `0 failures`.
Commit: `fix: render thumbsticks as textured 3D assemblies`.

### Task 3: True 3D Extreme 3D Pro assembly

**Files:**
- Create: `Sources/MatchSticksDS/Views/GamepadArtwork/FlightStickSceneView.swift`
- Create: `Sources/MatchSticksDS/Views/GamepadArtwork/ArtworkContour.swift`
- Modify: `Sources/MatchSticksDS/Views/GamepadArtwork/GamepadArtworkOverlay.swift`
- Create: `Tests/MatchSticksDSUITests/FlightStickSceneTests.swift`
- Modify: `scripts/test-ui.sh`

**Interfaces:**
- Produces: an inspectable scene with named `base`, `pivot`, `handle`, `shaft`, `twist` nodes; `update(left:twist:state:in:)` preserves a stationary base.
- Consumes: the existing calibrated `flightPivot` and 7°/16° input amplitudes.

- [x] **Step 1: Write failing scene-graph and snapshot tests**

Assert that `base.worldPosition` and `pivot.worldPosition` are invariant under all inputs, `handle` has nonzero extrusion depth, twist only changes the moving assembly, and neutral Euler angles are zero. Render neutral, front, back, left, right and twist states and confirm actual changing mesh occlusion.

- [x] **Step 2: Run tests and confirm the 3D assembly is absent**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-ui.sh`
Expected: missing scene API or bitmap-transform assertions fail.

- [x] **Step 3: Implement contour-derived solid geometry**

Build explicit source-pixel meshes with true sidewalls and beveled boundaries instead of relying on `SCNShape` triangulation of complex holes. Attach a real shaft and ball joint at the calibrated pivot. Reconstruct the central base beneath the old silhouette. Use proper 3D transforms and shadow-casting lights, with a front-facing camera. Keep state highlights attached to their physical base/handle nodes.

- [x] **Step 4: Verify real rendered movement and commit**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-ui.sh`
Expected: `0 failures`, with actual snapshots saved for neutral and each deflection.
Commit: `fix: animate the flight stick as a 3D assembly`.

### Task 4: High-resolution Direwolf 4 artwork and calibration

**Files:**
- Preserve: `Sources/MatchSticksDS/Resources/Gamepads/direwolf4-reference.png` (official 492×341 source)
- Modify: `Sources/MatchSticksDS/Resources/Gamepads/direwolf4.png` (rebuilt 1968×1364 artwork)
- Create: `Sources/MatchSticksDS/Resources/Gamepads/direwolf4-{left-stick,right-stick,well-left,well-right}.png`
- Create: `scripts/render-direwolf4.swift`
- Modify: `Sources/MatchSticksDS/Resources/Gamepads/ArtworkCredits.txt`
- Modify: `Sources/MatchSticksDS/Views/GamepadArtwork/GamepadArtwork.swift`
- Modify: `Tests/MatchSticksDSUITests/GamepadArtworkTests.swift`
- Create: `Tests/MatchSticksDSUITests/DirewolfArtworkTests.swift`
- Modify: `Tests/MatchSticksDSUITests/GamepadRenderingTests.swift`

**Interfaces:**
- Produces: a transparent, front-facing, default-white shell at no less than 1968×1364, plus an explicit reference-to-output transform for every control region.

- [x] **Step 1: Write failing asset tests**

Require the declared native dimensions, transparent corners, no resampled raster upscale, symmetric shell geometry, and control centers derived from the documented transform. Assert that cap textures and shell rendering are independently generated.

- [x] **Step 2: Verify the old asset fails the resolution test**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-ui.sh`
Expected: failure identifying the old 492×341 shell.

- [x] **Step 3: Rebuild and calibrate the asset**

Use the original alpha contour, logo geometry, front-view control positions and default-white reference. Reconstruct smooth geometry and high-resolution controls instead of sharpening the old PNG. Record the affine transform and source/rebuild attribution. If an official higher-resolution asset becomes available, use it instead with its actual source and dimensions.

- [x] **Step 4: Verify and commit**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-ui.sh`
Expected: `0 failures` and a clean high-resolution actual render.
Commit: `fix: rebuild Direwolf 4 artwork at native display resolution`.

### Task 5: Integration, final validation and delivery

**Files:**
- Modify: `engineering-log/2026.11.23.md` (local ignored file only; never stage)
- Review: all changed files and `Sources/MatchSticksDS/Resources/Gamepads/ArtworkCredits.txt`

- [ ] **Step 1: Run all regression checks**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run DSCoreTests`
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-ui.sh`
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-e2e.sh`
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-update.sh`
Expected: zero failures; E2E at least 40 Hz and isolated production preferences; update safety gates pass. Do not terminate another session to obtain ports.

- [ ] **Step 2: Review final rendered evidence and commit**

Inspect every skin's neutral and moving renders, including both thumbsticks and flight twist. Verify no new bitmap offset, timer, source license misattribution, or changed input mapping. Commit only the relevant source, resources, tests and ADR/plan.

- [ ] **Step 3: Merge and verify the merged tree**

Push once, create a PR to `beta`, merge after checks, read back the merge commit, and create a final delivery worktree. Re-run all four standard checks if the tree differs. Never merge to `stable` or create a Release.

- [ ] **Step 4: Build, back up, install, inspect and log**

Steps 3 and 4 run after the single push; their outcome is recorded in `engineering-log` rather than in this file.


Build `0.1.0-beta.20261123.natural-controller-motion` with both architectures and deep+strict signing. Back up the installed app only after confirming it is disconnected, disabled and free of E-Stop; replace it, launch the exact installed path, inspect all affected skins, and record the actual version, safety state, PR, merge commit, asset provenance, DMG hash and any remaining physical-controller verification limits. Close test windows and background tasks; do not leave the production app running without a current user request to keep it open.
