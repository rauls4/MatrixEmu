#!/usr/bin/env python3
"""Reference runner for MatrixEmu bytecode.

Executes the same ISA as the iOS app, clocks the same 1/16 HUB75 scan
model (row-pair select on A–D, latch, OE blanking), and writes scaled
PNGs of the 64x32 panel. Python 3 stdlib plus Pillow if it is installed;
otherwise a stdlib PNG writer is used.
"""

import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import assemble  # noqa: E402

WIDTH = 64
HEIGHT = 32
PAIRS = 16
# One full address sweep per virtual millisecond. Not cycle-accurate;
# long enough that a DELAY of >= 1 ms presents a complete POV frame.
MS_PER_FRAME = 1.0
PROGRAM_ADDR = assemble.PROGRAM_LOAD_ADDR


class Fault(Exception):
    pass


class Hub75:
    """64x32 panel, 1/16 scan. E (GPIO9) is held low; A–D select the row pair.

    Firmware never toggles these pins. PIX/FILL write `fb`. The scanner
    blanks (OE high), shifts 64 columns, pulses LAT, then drives OE low
    for that pair. The latched buffer is what persistence of vision shows.
    """

    def __init__(self):
        self.fb = bytearray(WIDTH * HEIGHT * 3)
        self.latched = bytearray(WIDTH * HEIGHT * 3)
        self.addr = 0
        self.slots = 0
        self.oe_high = True
        self.lat = False
        self.clk = False
        self.e = False  # GPIO9, unused on this 1/16 panel

    def clear_fb(self):
        self.fb[:] = b"\x00" * len(self.fb)

    def clear_latched(self):
        self.latched[:] = b"\x00" * len(self.latched)
        self.oe_high = True

    def pix(self, x, y, r, g, b):
        if not (0 <= x < WIDTH and 0 <= y < HEIGHT):
            return
        i = (y * WIDTH + x) * 3
        self.fb[i] = r & 255
        self.fb[i + 1] = g & 255
        self.fb[i + 2] = b & 255

    def fill(self, x, y, w, h, r, g, b):
        if w <= 0 or h <= 0:
            return
        for yy in range(y, y + h):
            if yy >= HEIGHT:
                break
            if yy < 0:
                continue
            for xx in range(x, x + w):
                if xx >= WIDTH:
                    break
                if xx < 0:
                    continue
                self.pix(xx, yy, r, g, b)

    def _copy_row(self, y):
        base = y * WIDTH * 3
        self.latched[base:base + WIDTH * 3] = self.fb[base:base + WIDTH * 3]

    def latch_pair(self, n):
        """Blank, shift 64 clocks, latch, unblank. n is the A–D address 0..15."""
        self.oe_high = True
        self.lat = False
        upper = n
        lower = n + 16
        for _x in range(WIDTH):
            self.clk = False
            # Column data is the framebuffer byte, not a 1-bit plane.
            # CLK still walks every column so the shift timing is present.
            self.clk = True
        self.clk = False
        self._copy_row(upper)
        self._copy_row(lower)
        self.lat = True
        self.lat = False
        self.addr = n & 15
        self.e = False
        self.oe_high = False

    def commit_all(self):
        self.latched[:] = self.fb
        self.oe_high = False
        self.e = False

    def scan(self, ms):
        if ms <= 0:
            return
        pairs = int(ms / MS_PER_FRAME * PAIRS)
        if pairs <= 0:
            return
        # A full refresh is 16 row pairs (1 ms). Any span that covers a
        # whole refresh presents the current framebuffer on every row.
        if pairs >= PAIRS:
            self.commit_all()
        else:
            for i in range(pairs):
                self.latch_pair((self.slots + i) % PAIRS)
        self.slots += pairs
        self.addr = (self.slots - 1) % PAIRS
        self.oe_high = False
        self.e = False


class VM:
    def __init__(self, code):
        self.code = bytes(code)
        self.pc = 0
        self.regs = [0] * 8
        self.time_ms = 0.0
        self.delay_left = 0.0
        self.halted = False
        self.fault = None
        self.burst = 0
        self.hub = Hub75()
        self.millis_reads = 0

    def advance(self, budget_ms):
        if self.halted or self.fault:
            return
        left = float(budget_ms)
        while left > 0:
            if self.delay_left > 0:
                step = min(left, self.delay_left)
                self.hub.scan(step)
                self.delay_left -= step
                self.time_ms += step
                left -= step
                self.burst = 0
                continue
            if not self._exec():
                break

    def run_until(self, target_ms):
        self.advance(max(0.0, target_ms - self.time_ms))

    def _need(self, n):
        if self.pc + n > len(self.code):
            raise Fault(f"truncated instruction at pc {self.pc}")
        b = self.code[self.pc:self.pc + n]
        self.pc += n
        return b

    def _reg(self, v):
        if v > 7:
            raise Fault(f"bad register r{v} at pc {self.pc}")
        return v

    def _u8_reg(self, idx):
        return self.regs[self._reg(idx)] & 0xFF

    def _exec(self):
        try:
            if self.pc >= len(self.code):
                raise Fault("program counter ran off the segment")
            self.burst += 1
            if self.burst > 100000:
                raise Fault("program did not delay or halt")
            op = self._need(1)[0]
            if op == assemble.OP_NOP:
                return True
            if op == assemble.OP_PIXI:
                x, y, r, g, b = self._need(5)
                self.hub.pix(x, y, r, g, b)
                return True
            if op == assemble.OP_FILLI:
                x, y, w, h, r, g, b = self._need(7)
                self.hub.fill(x, y, w, h, r, g, b)
                return True
            if op == assemble.OP_DELAY:
                (ms,) = struct.unpack("<H", self._need(2))
                self.delay_left = float(ms)
                return True
            if op == assemble.OP_MILLIS:
                rd = self._reg(self._need(1)[0])
                self.regs[rd] = int(self.time_ms) & 0xFFFFFFFF
                self.millis_reads += 1
                return True
            if op == assemble.OP_HALT:
                self.halted = True
                self.hub.clear_latched()
                self.hub.oe_high = True
                return False
            if op == assemble.OP_CLR:
                self.hub.clear_fb()
                return True
            if op == assemble.OP_JMP:
                (off,) = struct.unpack("<H", self._need(2))
                if off > len(self.code):
                    raise Fault(f"jump target {off} is outside the segment")
                self.pc = off
                return True
            if op == assemble.OP_LDI:
                rd = self._reg(self._need(1)[0])
                (imm,) = struct.unpack("<I", self._need(4))
                self.regs[rd] = imm
                return True
            if op == assemble.OP_ADD:
                rd = self._reg(self._need(1)[0])
                rs = self._reg(self._need(1)[0])
                (imm,) = struct.unpack("<h", self._need(2))
                self.regs[rd] = (self.regs[rs] + imm) & 0xFFFFFFFF
                return True
            if op in (assemble.OP_BLT, assemble.OP_BGE, assemble.OP_BEQ):
                ra = self._reg(self._need(1)[0])
                rb = self._reg(self._need(1)[0])
                (off,) = struct.unpack("<H", self._need(2))
                if off > len(self.code):
                    raise Fault(f"branch target {off} is outside the segment")
                a, b = self.regs[ra], self.regs[rb]
                take = False
                if op == assemble.OP_BLT:
                    take = a < b
                elif op == assemble.OP_BGE:
                    take = a >= b
                else:
                    take = a == b
                if take:
                    self.pc = off
                return True
            if op == assemble.OP_PIXR:
                rx, ry, rr, rg, rb = self._need(5)
                self.hub.pix(
                    self._u8_reg(rx),
                    self._u8_reg(ry),
                    self._u8_reg(rr),
                    self._u8_reg(rg),
                    self._u8_reg(rb),
                )
                return True
            if op == assemble.OP_FILLR:
                rx, ry, rw, rh, rr, rg, rb = self._need(7)
                self.hub.fill(
                    self._u8_reg(rx),
                    self._u8_reg(ry),
                    self._u8_reg(rw),
                    self._u8_reg(rh),
                    self._u8_reg(rr),
                    self._u8_reg(rg),
                    self._u8_reg(rb),
                )
                return True
            raise Fault(f"invalid opcode 0x{op:02X} at pc {self.pc - 1}")
        except Fault as exc:
            self.fault = str(exc)
            self.halted = True
            return False


def _png_stdlib(path, rgb, w, h):
    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    Path(path).write_bytes(png)


def render_panel(latched, scale=12, bezel=28):
    """Return RGB bytes, width, height. Black bezel, round pixels."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        Image = None

    w = bezel * 2 + WIDTH * scale
    h = bezel * 2 + HEIGHT * scale
    if Image is None:
        buf = bytearray(w * h * 3)
        # stdlib fallback: filled discs, no antialias
        rad = max(1, int(scale * 0.38))
        rad2 = rad * rad
        for y in range(HEIGHT):
            for x in range(WIDTH):
                i = (y * WIDTH + x) * 3
                r, g, b = latched[i], latched[i + 1], latched[i + 2]
                on = r or g or b
                cx = bezel + x * scale + scale // 2
                cy = bezel + y * scale + scale // 2
                col = (r, g, b) if on else None
                for dy in range(-rad, rad + 1):
                    for dx in range(-rad, rad + 1):
                        if dx * dx + dy * dy > rad2:
                            continue
                        px, py = cx + dx, cy + dy
                        if not (0 <= px < w and 0 <= py < h):
                            continue
                        o = (py * w + px) * 3
                        if col is None:
                            edge = dx * dx + dy * dy > (rad - 1) * (rad - 1)
                            if edge:
                                buf[o:o + 3] = b"\x37\x37\x3a"
                        else:
                            buf[o:o + 3] = bytes(col)
        return bytes(buf), w, h

    im = Image.new("RGB", (w, h), (0, 0, 0))
    dr = ImageDraw.Draw(im)
    dr.rounded_rectangle([4, 4, w - 5, h - 5], radius=16, outline=(32, 32, 34), width=3)
    rad = scale * 0.36
    for y in range(HEIGHT):
        for x in range(WIDTH):
            i = (y * WIDTH + x) * 3
            r, g, b = latched[i], latched[i + 1], latched[i + 2]
            cx = bezel + x * scale + scale / 2
            cy = bezel + y * scale + scale / 2
            box = [cx - rad, cy - rad, cx + rad, cy + rad]
            if r == 0 and g == 0 and b == 0:
                dr.ellipse(box, outline=(55, 55, 58), width=max(1, scale // 10))
            else:
                glow = rad + scale * 0.22
                dr.ellipse(
                    [cx - glow, cy - glow, cx + glow, cy + glow],
                    fill=(r // 3, g // 3, b // 3),
                )
                dr.ellipse(box, fill=(r, g, b))
    return im.tobytes(), w, h


def save_png(path, latched):
    rgb, w, h = render_panel(latched)
    try:
        from PIL import Image
        Image.frombytes("RGB", (w, h), rgb).save(path)
    except ImportError:
        _png_stdlib(path, rgb, w, h)
    return rgb, w, h


def summarize(latched):
    lit = []
    sr = sg = sb = 0
    for y in range(HEIGHT):
        for x in range(WIDTH):
            i = (y * WIDTH + x) * 3
            r, g, b = latched[i], latched[i + 1], latched[i + 2]
            if r or g or b:
                lit.append((x, y, r, g, b))
                sr += r
                sg += g
                sb += b
    if not lit:
        return "no lit LEDs"
    xs = [p[0] for p in lit]
    ys = [p[1] for p in lit]
    return (
        f"{len(lit)} lit LEDs, bbox x {min(xs)}-{max(xs)} y {min(ys)}-{max(ys)}, "
        f"sum RGB {sr},{sg},{sb}, sample {lit[0]}"
    )


def _expect_error(blob, needle):
    try:
        assemble.parse_image(blob)
    except assemble.ImageError as exc:
        text = str(exc)
        if needle not in text:
            raise SystemExit(f"expected {needle!r} in {text!r}")
        print(f"reject: {text}")
        return
    raise SystemExit("parser accepted a file it should reject")


def self_check(image):
    code = assemble.parse_image(image)
    if image[0] != 0xE9:
        raise SystemExit("magic missing")
    if struct.unpack_from("<H", image, 12)[0] != 0x0009:
        raise SystemExit("chip id is not ESP32-S3")
    print(f"parsed demo: bytecode {len(code)} bytes, file {len(image)} bytes")

    _expect_error(b"\x00" * 64, "not an ESP32 image")
    _expect_error(bytes(range(256)), "not an ESP32 image")
    junk = bytearray(image)
    junk[40] ^= 0xFF
    _expect_error(bytes(junk), "not an ESP32 image")
    other = assemble.build_image(b"\x05\x00\x00\x00", load_addr=0x3FC88000)
    _expect_error(other, "no program segment at 0x3FC00000")


def main():
    root = Path(__file__).resolve().parents[1]
    src = root / "firmware" / "demo.asm"
    dest = root / "firmware" / "demo.bin"
    preview = root / "preview"
    preview.mkdir(parents=True, exist_ok=True)

    image = assemble.assemble_file(src, dest)
    self_check(image)
    code = assemble.parse_image(image)
    vm = VM(code)

    targets = [300, 900, 1680, 2200, 3600]
    for t in targets:
        vm.run_until(t)
        if vm.fault:
            raise SystemExit(f"fault at t={t}: {vm.fault}")
        path = preview / f"t{t:04d}ms.png"
        save_png(path, vm.hub.latched)
        # Re-open and count non-background pixels so a blank file fails the run.
        raw, w, h = render_panel(vm.hub.latched)
        colored = 0
        for i in range(0, len(raw), 3):
            r, g, b = raw[i], raw[i + 1], raw[i + 2]
            if r > 40 or g > 40 or b > 40:
                colored += 1
        if colored < 20:
            raise SystemExit(f"{path} looks blank ({colored} colored pixels)")
        desc = (
            f"t={vm.time_ms:.0f}ms addr={vm.hub.addr} OE={'blank' if vm.hub.oe_high else 'lit'} "
            f"millis_reads={vm.millis_reads} {summarize(vm.hub.latched)} "
            f"png_colored_px={colored} {w}x{h} -> {path.name}"
        )
        print(desc)
    if vm.millis_reads < 10:
        raise SystemExit("demo never executed MILLIS")
    print("ok")


if __name__ == "__main__":
    main()
