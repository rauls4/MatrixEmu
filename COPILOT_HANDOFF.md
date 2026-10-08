# Copilot Handoff — MatrixEmu

**What:** iOS (and notarized macOS) SwiftUI emulator of a Waveshare ESP32-S3-RGB-Matrix board driving a 64×32 HUB75 panel. Bundle id `com.raul.MatrixEmu`. Not a real Xtensa/QEMU emulator (see README).
**Location:** `~/dev/MatrixEmu` · **GitHub:** rauls4/MatrixEmu
**Branch / HEAD:** `main`, see `git log -1` (last updated 2026-10-07 ~10:30 PM CT with the pixel-emu icon commit). Mac 1.0 release is on GitHub Releases (it still ships the old bar-graph icon).

## Stack
SwiftUI, iOS 17+, no third-party packages. Python tooling in `firmware/` (assembler, sim, GIF→bin).

## Build / run
- Xcode: open `MatrixEmu.xcodeproj`, scheme **MatrixEmu** (only target/scheme; verified with `xcodebuild -list`).
- CLI: `xcodebuild -project MatrixEmu.xcodeproj -scheme MatrixEmu -destination 'generic/platform=iOS Simulator' build` (not run by the handoff author).
- Firmware tools: `firmware/assemble.py`, `firmware/sim.py`, `firmware/gif_to_bin.py`, `firmware/compile_ino.sh`.

## Layout
- `App/` — Swift sources (MatrixMachine, Hub75Scan, ESPImage, LEDPanelView, SketchCompiler, GIF/Text/FlipBook firmwares, samples)
- `firmware/` — bytecode assembler, simulator, sample binaries
- `preview/` — screenshots for README

## State / open work
- The shared scheme has the debugger off for Run (launcher PosixSpawn) on purpose: Raul turned it off because it slows builds. Turn it on locally only when you need to debug, and don't commit it back on.
- Open work: unknown (no TODOs in sources). The new icon isn't in a release build yet.

## Standing rules for AI agents
- Keep this doc current after every meaningful change: branch, HEAD sha, state, next steps. Then commit and push.
- Never commit secrets: `.env`, `.dev.vars`, keystores (`*.jks`, `*.keystore`, `keystore.properties`), `local.properties`, signing certs (`*.p12`), API keys, login sessions.
- Never force-push, rewrite pushed history, or delete branches without Raul's explicit OK.
- Don't commit build output (`build/`, `Build/`, `DerivedData/`, `.gradle/`, `node_modules/`).
- Write "unknown" rather than guessing.

## 2026-10-07: local-only folders (gitignored)
- `Archives/MatrixEmu.xcarchive`: com.raul.MatrixEmu 1.0 (1), archived Oct 3, 2026 at 10:33 AM CT (moved from the Desktop).
- `Signing/MatrixAppleDev.certSigningRequest`: the Apple Developer certificate signing request.
- `Materials/animation.bin`: from "Desktop/MatrixEmu Materials".
The Desktop copy of the repo had nothing that wasn't already in git; it's backed up at `~/.pixelpop-move-backups/MatrixEmu-desktop-20261007`.

## 2026-10-07: pixel-emu app icon
- The rainbow bar-graph icon was replaced with a pixel-art emu drawn on the same LED-dot panel (26x26 LED grid, blue head and neck, brown body, grey legs). All 19 PNGs in `App/Assets.xcassets/AppIcon.appiconset/` plus `preview/app-icon.png` were regenerated at their exact old sizes, as RGB with no alpha. `Contents.json` is unchanged.
- Below 120 px the unlit LED rings are dropped and the lit LEDs drawn solid so the emu stays readable.
- Verified: the iOS Simulator and macOS (unsigned) builds both succeeded with no asset-catalog warnings.
- The old icon files are still in git history (the commit before the icon change).
- Related: PixelPop's rauls4/PixelPopEmu was copied from this repo at 687738e. It is independent, so changes here don't affect it.
- SpriteSheet Doctor's test suite uses the local `firmware/` tools when they exist, so give its assistant a heads-up before changing them.
