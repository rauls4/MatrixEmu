# Copilot Handoff — MatrixEmu

**What:** iOS (and notarized macOS) SwiftUI emulator of a Waveshare ESP32-S3-RGB-Matrix board driving a 64×32 HUB75 panel. Bundle id `com.raul.MatrixEmu`. Not a real Xtensa/QEMU emulator (see README).
**Location:** `~/dev/MatrixEmu` · **GitHub:** rauls4/MatrixEmu
**Branch / HEAD:** `main` @ `410ee58` (2026-10-07, before this doc). Mac 1.0 release is on GitHub Releases.

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
- Uncommitted on 2026-10-07: `MatrixEmu.xcodeproj/xcshareddata/xcschemes/MatrixEmu.xcscheme` modified (left uncommitted; unknown intent).
- Open work: unknown (no TODOs in sources).

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
