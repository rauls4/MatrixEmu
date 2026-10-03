# MatrixEmuPlayer

Arduino-ESP32 sketch for the Waveshare **ESP32-S3-RGB-Matrix** + **RGB-Matrix-P3-64x32**.

Flash this sketch **once**. After that, animations you Share from the iOS app
(`animation.bin`) are what the board plays — they are **not** full ESP-IDF
applications and must not be flashed as the device firmware by themselves.

## Board / pins

Same map as the app README: R1=4 G1=5 B1=6 R2=7 G2=15 B2=16 A=18 B=8 C=3 D=42
E=9 (held low) CLK=41 LAT=40 OE=2 (active low).

## Build / flash the player

From the repo root, on a Mac or Linux host with `arduino-cli` and the `esp32:esp32` core (not on the iPhone):

```sh
firmware/compile_ino.sh firmware/player/MatrixEmuPlayer.ino firmware/player/MatrixEmuPlayer.bin
```

That writes `MatrixEmuPlayer.bin` in this directory (ESP32-S3 application image, FQBN `esp32:esp32:esp32s3`), plus the bootloader, partition table, and `MatrixEmuPlayer.flash_args`. Flash from this directory:

```sh
esptool.py --chip esp32s3 write_flash @MatrixEmuPlayer.flash_args
```

Arduino IDE 2.x also works: board ESP32S3 Dev Module, USB CDC on Boot enabled, then upload. See the repo README section "Compile an .ino".

## Loading an animation

1. In the iOS app, Import GIF / Show text / Play flip-book / Load .bin, then tap
   **Share animation**. The file is always named `animation.bin` and is labeled
   as a MatrixEmu animation image for this player.
2. Copy it to the board LittleFS as `/animation.bin` (Arduino IDE data upload,
   or any LittleFS tool). Reboot. The player parses the ESP-shaped container,
   runs the bytecode segment at `0x3FC00000`, and loops.
3. If no file is present, a tiny embedded color-bar loop runs so you can verify
   the panel wiring.
