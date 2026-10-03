# MatrixEmu

iOS emulator of a Waveshare **ESP32-S3-RGB-Matrix** driver board with a Waveshare **RGB-Matrix-P3-64x32** panel on the HUB75 port. The on-screen name is Matrix. Bundle id `com.raul.MatrixEmu`. Portrait only. iOS 17+, SwiftUI, no third-party packages.

## Download the Mac app

macOS 14 or later, Apple silicon.

[MatrixEmu 1.0 for Mac](https://github.com/rauls4/MatrixEmu/releases/latest/download/MatrixEmu-1.0-macOS.zip)

Unzip the download and open `MatrixEmu`. The first time, macOS blocks it because this copy is signed with a Developer ID but not notarized yet. Control-click the app, choose Open, then Open again. After that it launches with a normal double-click.

This is not QEMU and not an Xtensa LX7 or ESP-IDF emulator. There is no Wi-Fi, Bluetooth, FreeRTOS, or GPIO bitbanging of arbitrary firmware. A real ESP32-S3 application image is accepted or rejected by its header, and one RAM segment is executed as a small bytecode program. The panel is updated by a HUB75 scan model, not by pretending the framebuffer is a memory-mapped display.

## Board

Product: [ESP32-S3-RGB-Matrix](https://docs.waveshare.com/ESP32-S3-RGB-Matrix) (SKU 34422), ESP32-S3-N32R16. This is the HUB75 driver board, not the separate ESP32-S3-Matrix board (that one is an 8×8 WS2812 module).

Panel: [RGB-Matrix-P3-64x32](https://www.waveshare.com/wiki/RGB-Matrix-P3-64x32), 64×32, 3 mm pitch, 1/16 scan, HUB75. Waveshare's LED-matrix chapter uses the same driver with a 64×64 1/32 panel; a 64×32 module only needs address lines A–D. E is wired on the driver and left low here.

GPIO map, from Waveshare's "Confirm the Pins" table in [ESP32 LED Matrix](https://docs.waveshare.com/ESP32-Peripheral-Tutorials/Display/LED-Matrix) (section 4.2). These are fixed traces on the ESP32-S3-RGB-Matrix, not the generic ESP32 HUB75 example on the panel wiki.

| Signal | GPIO | Signal | GPIO |
| --- | --- | --- | --- |
| R1 | 4 | R2 | 7 |
| G1 | 5 | G2 | 15 |
| B1 | 6 | B2 | 16 |
| A | 18 | B | 8 |
| C | 3 | D | 42 |
| E | 9 (held low) | CLK | 41 |
| LAT | 40 | OE | 2 (active low) |

Scan: for address `n` in 0…15 the scanner blanks OE, clocks 64 columns, pulses LAT, then enables row `n` and row `n+16`. One full sweep is treated as 1 ms of virtual time. The picture on screen is the latched persistence-of-vision frame. Firmware does not drive these pins. It writes the framebuffer through the opcodes below; the scanner copies that buffer out.

## Firmware image

ESP-IDF / esptool application image for ESP32-S3:

| Offset | Contents |
| --- | --- |
| 0 | Magic `0xE9` |
| 1 | Segment count |
| 2 | Flash mode |
| 3 | Flash size (high nibble) and speed (low nibble) |
| 4 | Entry address, uint32 LE (`0x3FC00000` for images this assembler writes) |
| 8 | Extended header, 16 bytes. Chip id uint16 at file offset 12 is `0x0009`. Byte 23 is the hash flag. |
| 24 | Segments. Each is uint32 load address, uint32 length, then that many bytes. Length is a multiple of 4. |
| after segments | `0x00` padding, then one checksum byte, placed so the image length so far is a multiple of 16. Checksum is `0xEF` XOR every payload byte. |
| after checksum | 32-byte SHA-256 of the preceding bytes when the hash flag is 1. |

A file is rejected when the magic, chip id, segment framing, checksum, or hash does not match. It is also rejected, with an explicit message, when no segment is loaded at `0x3FC00000`.

That address is the contract for this emulator. Stock ESP-IDF links app DRAM at `0x3FC88000`, not `0x3FC00000`. A normal IDF binary will parse as an ESP32-S3 image and then fail the segment check unless something was actually linked there.

## Bytecode

Registers `r0`–`r7` are 32-bit and start at 0. The program counter is a byte offset into the `0x3FC00000` segment. Multi-byte immediates are little-endian. Virtual time starts at 0 and advances only on `delay`. Pixel coordinates and colors taken from registers use the low 8 bits. Branches compare full unsigned register values. Jump targets are absolute bytecode offsets.

| Opcode | Byte | Encoding | Effect |
| --- | --- | --- | --- |
| nop | `0x00` | | No effect. Also used to pad the segment to 4 bytes. |
| pixi | `0x01` | u8 x, y, r, g, b | Set one pixel, clipped to 64×32. |
| filli | `0x02` | u8 x, y, w, h, r, g, b | Fill a rectangle, clipped. |
| delay | `0x03` | u16 ms | Block the VM and run the HUB75 scan for that many virtual milliseconds. |
| millis | `0x04` | u8 rd | `rd` = virtual milliseconds so far, truncated to 32 bits. |
| halt | `0x05` | | Stop. OE is held blank and the latched image is cleared. A real panel does not hold a picture without refresh. |
| clr | `0x06` | | Clear the framebuffer. The panel updates on the next scan. |
| jmp | `0x10` | u16 abs | Jump. |
| ldi | `0x11` | u8 rd, u32 imm | Load immediate. |
| add | `0x12` | u8 rd, u8 rs, i16 imm | `rd = rs + imm`, wrapping. |
| blt | `0x13` | u8 ra, u8 rb, u16 abs | Jump if `ra < rb` (unsigned). |
| bge | `0x14` | u8 ra, u8 rb, u16 abs | Jump if `ra >= rb`. |
| beq | `0x15` | u8 ra, u8 rb, u16 abs | Jump if `ra == rb`. |
| pixr | `0x16` | u8 rx, ry, rr, rg, rb | `pixi` from registers. |
| fillr | `0x17` | u8 rx, ry, rw, rh, rr, rg, rb | `filli` from registers. |

Anything else is an invalid opcode and stops the machine with an error.

`firmware/demo.asm` sweeps a 3-pixel-wide bar across the panel (red, then green, then blue, 30 ms per step) and then bounces a 2×2 white dot. `millis` runs every frame; the demo does not branch on the value. The loop is the bounce, not `halt`.

## Assemble

Python 3 standard library only.

```sh
python3 firmware/assemble.py firmware/demo.asm firmware/demo.bin
```

With no arguments it reads `firmware/demo.asm` and writes `firmware/demo.bin` next to the script.

Text format: `;` comments, `label:` on its own or at the start of a line, commas optional. Registers are `r0`–`r7`. Example:

```
ldi r0, 0
loop:
    filli 0, 0, 64, 32, 0, 0, 0
    pixr r0, r0, r1, r1, r1
    delay 40
    add r0, r0, 1
    ldi r2, 32
    blt r0, r2, loop
```

`firmware/sim.py` is the same machine and the same scan, and writes scaled PNGs (black bezel, round pixels) to `preview/`. Pillow is used when it is installed; otherwise the script writes PNG with `zlib` and `struct`.

```sh
python3 firmware/sim.py
```

## Xcode

1. Open `MatrixEmu.xcodeproj`.
2. Scheme **MatrixEmu**. Destinations: an iPhone simulator (iOS 17+) or **My Mac** (macOS 14+). The target’s `SUPPORTED_PLATFORMS` includes `iphoneos`, `iphonesimulator`, and `macosx`.
3. Run. `firmware/demo.bin` is in Copy Bundle Resources and loads on launch.

Signing is off (`CODE_SIGNING_ALLOWED = NO`) so a simulator build does not ask for a team. For a device, turn signing on and pick a team. There are no Swift packages to resolve.

Controls: play/pause, reset, 1× and 4×, firmware name, Load .bin, Import GIF, Share animation, Compile sketch, text composer, and flip-book editor. Pause freezes virtual time and holds the last latched frame. A file that is not an ESP32-S3 image, or that has no segment at `0x3FC00000`, leaves the current program in place and shows the error.

The panel is one SwiftUI `Canvas`: 64 columns by 32 rows of round LEDs. Off LEDs are dim hollow gray dots. On LEDs are solid RGB with a small glow.

The app icon is `preview/app-icon.png` (dark rounded bezel, LED bar graph). That file is copied into `App/Assets.xcassets/AppIcon.appiconset` at 1024×1024 (iOS marketing and the Mac 512pt @2x image) and downscaled for the iPhone and Mac sizes Xcode expects. `ASSETCATALOG_COMPILER_APPICON_NAME` is `AppIcon`.

On Mac, **Compile sketch** runs `arduino-cli` on that Mac (`Process`, sandbox off, no extra certificate). On iPhone the same button only saves and shares the `.ino`. The phone never compiles Xtensa.


## Import GIF

**Import GIF** opens a system picker (`UTType.gif` / images). The app decodes frames with ImageIO, composites them with GIF disposal, aspect-fill center-crops each frame to 64×32, skips near-black pixels (`r+g+b < 24`), and emits MatrixEmu bytecode (`clr`, `pixi`, `delay`, then `jmp 0` to loop). At most 60 frames (evenly subsampled if longer). Frame delay comes from the GIF (centiseconds → ms); missing or zero delay becomes 100 ms. The resulting file is this emulator’s ESP32-S3-shaped **animation image** (segment at `0x3FC00000`), not a stock ESP-IDF / Arduino sketch. On failure the current firmware keeps running and an error is shown. The imported file name is shown as the firmware name.

`firmware/gif_to_bin.py` builds the same kind of `.bin` from a GIF (stdlib + Pillow when present) and can write `preview/gif-frame0.png` / `gif-frame1.png`.

## Text on the matrix

Type a message, pick a default color and optional per-letter colors (red, orange, yellow, green, cyan, blue, white), choose an effect, and tap **Show**. Effects: **Static**, **Slide in** (from the right), **Typewriter**, **Scroll** (continuous marquee). Long strings scroll instead of clipping. Empty text does not replace the current firmware. Output is the same animation image format (5×7 bitmap font, one-pixel letter gap).

## Flip-book

**Edit frames** paints a 64×32 flip-book on the phone (tap/drag, palette, clear / prev / next / add / delete, delay slider default 100 ms). **Play flip-book** builds the same looping animation `.bin` and loads it immediately.

## Share animation

**Share animation** exports the currently loaded program as `animation.bin` via the system share sheet. The UI labels it as a MatrixEmu **animation image for the board player**, not a flashable stock ESP-IDF application by itself.

## Board player

`firmware/player/MatrixEmuPlayer.ino` is an Arduino-ESP32 sketch for the Waveshare ESP32-S3-RGB-Matrix (same HUB75 GPIO map as above). Flash that sketch **once**. Then copy a shared `animation.bin` to LittleFS as `/animation.bin`. The player extracts the bytecode segment at `0x3FC00000` and loops it on the 64×32 panel. See `firmware/player/README.md`. Build the player with the command below, not on the iPhone.

## Compile an .ino

The iPhone cannot compile Xtensa or run ESP-IDF / Arduino-ESP32. **Compile sketch** on iOS stores the `.ino` you pick and opens the share sheet so you can send that source to a Mac. On the Mac app, the same button invokes `arduino-cli` (FQBN `esp32:esp32:esp32s3`) via `Process` and, if a real image is produced, loads it. A stock Arduino image has no bytecode segment at `0x3FC00000`, so the emulator reports that and keeps the current animation. If `arduino-cli` or the `esp32:esp32` core is missing, the app shows install steps and does not invent a `.bin`. `idf.py` is not an `.ino` compiler; the app says so when only ESP-IDF is installed.

Command-line equivalent, from the repo root on a Mac or Linux host that already has Arduino CLI and the ESP32 core:

```sh
firmware/compile_ino.sh firmware/player/MatrixEmuPlayer.ino firmware/player/MatrixEmuPlayer.bin
```

That writes a real ESP32-S3 application image to `firmware/player/MatrixEmuPlayer.bin`. The same run also writes, next to it:

- `MatrixEmuPlayer.bootloader.bin` (typically flash offset 0x0)
- `MatrixEmuPlayer.partitions.bin` (typically 0x8000)
- `MatrixEmuPlayer.boot_app0.bin` when the core emits it
- `MatrixEmuPlayer.flash_args` (esptool arguments from that build)

Flash from `firmware/player`:

```sh
esptool.py --chip esp32s3 write_flash @MatrixEmuPlayer.flash_args
```

Override the board with `FQBN=...`. For the Waveshare ESP32-S3-N32R16 (32 MB flash, OPI PSRAM, LittleFS, USB CDC on boot):

```sh
FQBN='esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=32M,PSRAM=opi,PartitionScheme=app5M_little24M_32MB' \
  firmware/compile_ino.sh firmware/player/MatrixEmuPlayer.ino firmware/player/MatrixEmuPlayer.bin
```

The default FQBN is `esp32:esp32:esp32s3`. Checked on the project Mac: `arduino-cli` 1.5.1 at `/opt/homebrew/bin/arduino-cli`, core `esp32:esp32` 3.3.11 in `~/Library/Arduino15`. `idf.py` was not installed. The script does not download the core.

If `arduino-cli` is missing, or the core is missing, `firmware/compile_ino.sh` exits with:

```sh
brew install arduino-cli
arduino-cli core update-index
arduino-cli core install esp32:esp32
```

## Controllers

The default is the Waveshare **ESP32-S3-RGB-Matrix** with a **64×32** HUB75 panel (1/16 scan, E held low). The **Controller** picker also selects:

- Generic HUB75 **64×32** (same 1/16 scan, not the Waveshare pin map)
- Generic HUB75 **64×64** (1/32 scan, address A–E)
- MAX7219 / FC-16, four 8×8 modules, **32×8**, shown amber
- WS2812 / NeoPixel **8×8** and **16×16** (one RGB LED per pixel, no row mux)

GIF import, text, and the flip-book use the selected width and height. This is not every LED controller. The board player sketch stays the Waveshare 64×32 build. **Share animation** still writes `animation.bin` for that player.

## Samples

**Samples** lists seven bundled loops. Tap one to load and play it. **Share animation** exports whichever image is loaded, including a sample. They are MatrixEmu animation images (segment at `0x3FC00000`), authored for 64×32, so a smaller panel clips them. Sources are `firmware/samples/*.asm`, assembled with `firmware/assemble.py`. The app copies are in `App/Samples/`:

- `rainbow-sweep.bin` — Rainbow sweep
- `bouncing-dot.bin` — Bouncing dot
- `scrolling-hello.bin` — Scrolling HELLO
- `sparkle.bin` — Sparkle
- `checker-fade.bin` — Checker fade
- `dancing-bears.bin` — Dancing Bears (six Grateful Dead bears, red through purple)
- `nyan-cat.bin` — Nyan Cat (pop-tart, gray head, scrolling rainbow, and “Raul needs to sleep!”)

## Rotation and sound

**Rotation** is 0°, 90°, 180°, or 270°, clockwise. It only changes how the latched framebuffer is drawn. Bytecode coordinates and the controller width and height stay the same, so a 90° or 270° turn swaps the on-screen aspect ratio without resizing the buffer.

**Sound** plays while an animation is running. Nyan Cat uses a short original pulse-wave loop written for this sample (not the Nyan Cat song). Every other animation uses the same soft tick. **Mute** stops it; **Pause** stops it until **Play**. iOS sets `AVAudioSession` to `.playback` mixed with other audio. macOS uses the same `AVAudioEngine` loop.

## Limits

- Not a CPU emulator. ESP-IDF, Arduino, Wi-Fi, and FreeRTOS binaries will not run, even when the image header is valid.
- The program must live at `0x3FC00000`. That is not the ESP32-S3 DRAM base used by ESP-IDF (`0x3FC88000`).
- No binary-coded-modulation bit planes and no cycle-accurate GPIO. Color in the framebuffer is what gets latched. CLK still steps once per column, and OE blanks around the latch, but the firmware never writes those pins.
- E (GPIO9) is not part of the 1/16 scan. A 64×64 1/32 panel is not what this build drives.
- Virtual time moves only inside `delay`. A loop with no `delay` and no `halt` stops after 100000 instructions.
- `halt` blanks the panel. Pause does not.
