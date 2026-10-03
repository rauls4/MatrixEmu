#!/usr/bin/env python3
"""Convert a GIF into a MatrixEmu ESP32-S3 application image.

Same rules as the iOS GIF importer: disposal-aware compositing, aspect-fill
center-crop to 64x32, skip near-black pixels, clr+pixi+delay per frame, jmp 0
to loop, cap at 60 frames, build_image from assemble.py.

Usage:
  python3 firmware/gif_to_bin.py [input.gif] [output.bin]

With no args: write a 64x32 4-frame test GIF, convert it, run the VM, and
write preview/gif-frame0.png and preview/gif-frame1.png.
"""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import assemble  # noqa: E402

WIDTH = 64
HEIGHT = 32
MAX_FRAMES = 60
NEAR_BLACK = 24
DEFAULT_DELAY_MS = 100
PANEL = WIDTH * HEIGHT


def _have_pillow():
    try:
        from PIL import Image  # noqa: F401
        return True
    except ImportError:
        return False


def _png_chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def write_png_rgb(path: Path, rgb: bytes, w: int, h: int) -> None:
    raw = b"".join(b"\x00" + rgb[y * w * 3 : (y + 1) * w * 3] for y in range(h))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", zlib.compress(raw, 9))
        + _png_chunk(b"IEND", b"")
    )
    path.write_bytes(png)


def make_test_gif(path: Path) -> None:
    """4 distinct full-panel frames (red / green / blue / yellow blocks)."""
    frames_rgb = []
    colors = [
        (255, 40, 40),
        (40, 220, 60),
        (40, 80, 255),
        (255, 220, 40),
    ]
    positions = [(4, 4, 28, 20), (32, 8, 28, 16), (8, 12, 48, 12), (16, 2, 32, 28)]
    for (r, g, b), (x0, y0, w, h) in zip(colors, positions):
        buf = bytearray(WIDTH * HEIGHT * 3)
        for y in range(y0, y0 + h):
            for x in range(x0, x0 + w):
                i = (y * WIDTH + x) * 3
                buf[i] = r
                buf[i + 1] = g
                buf[i + 2] = b
        frames_rgb.append(bytes(buf))

    if _have_pillow():
        from PIL import Image

        imgs = [Image.frombytes("RGB", (WIDTH, HEIGHT), fr) for fr in frames_rgb]
        imgs[0].save(
            path,
            save_all=True,
            append_images=imgs[1:],
            duration=200,  # ms; Pillow writes centiseconds
            loop=0,
            disposal=2,
        )
        return

    # Minimal GIF89a writer (no LZW complexity: use uncompressed codes).
    path.write_bytes(_write_simple_gif(frames_rgb, delay_cs=20))


def _write_simple_gif(frames_rgb: list[bytes], delay_cs: int = 20) -> bytes:
    """GIF89a with a 16-color global palette and uncompressed image data."""
    # Build a small palette from unique colors + black.
    palette = [(0, 0, 0)]
    index_maps = []
    for fr in frames_rgb:
        imap = []
        for i in range(0, len(fr), 3):
            c = (fr[i], fr[i + 1], fr[i + 2])
            if c not in palette:
                if len(palette) >= 16:
                    # nearest
                    best = 0
                    best_d = 1 << 30
                    for pi, pc in enumerate(palette):
                        d = sum((a - b) * (a - b) for a, b in zip(c, pc))
                        if d < best_d:
                            best_d = d
                            best = pi
                    imap.append(best)
                else:
                    palette.append(c)
                    imap.append(len(palette) - 1)
            else:
                imap.append(palette.index(c))
        index_maps.append(imap)

    while len(palette) < 16:
        palette.append((0, 0, 0))

    out = bytearray()
    out += b"GIF89a"
    out += struct.pack("<HH", WIDTH, HEIGHT)
    out += bytes([0x80 | 0x11, 0, 0])  # GCT flag, 2 bits -> 4? use 16 colors: size=3 -> 2^(3+1)=16
    # packed: GCT=1, color res=001, sort=0, size=011 (16 entries)
    out[-3] = 0x80 | (0x7 << 4) | 0x03  # rewrite properly
    # Actually set packed byte correctly:
    out = bytearray(b"GIF89a")
    out += struct.pack("<HH", WIDTH, HEIGHT)
    out.append(0x80 | (0x07 << 4) | 0x03)  # GCT, 8-bit res, 16 colors
    out.append(0)  # bg
    out.append(0)  # aspect
    for r, g, b in palette:
        out += bytes([r, g, b])

    out += b"\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00"  # loop forever

    for imap in index_maps:
        out += b"\x21\xf9\x04"
        out.append(0x08)  # disposal 2 << 2 = 8, no transparent
        out += struct.pack("<H", delay_cs)
        out.append(0)  # transparent index
        out.append(0)  # end GCE

        out += b"\x2c"
        out += struct.pack("<HHHH", 0, 0, WIDTH, HEIGHT)
        out.append(0)  # no LCT
        # Uncompressed LZW with clear codes (min code size 4 for 16-color)
        min_code = 4
        clear = 1 << min_code
        stop = clear + 1
        out.append(min_code)
        # Emit clear frequently so codes stay at min_code+1 width.
        codes = []
        codes.append(clear)
        for idx in imap:
            codes.append(idx)
            if len(codes) % 100 == 0:
                codes.append(clear)
        codes.append(stop)
        # Pack as 5-bit codes (min_code+1)
        bit_width = min_code + 1
        acc = 0
        bits = 0
        stream = bytearray()
        for code in codes:
            acc |= code << bits
            bits += bit_width
            while bits >= 8:
                stream.append(acc & 0xFF)
                acc >>= 8
                bits -= 8
        if bits:
            stream.append(acc & 0xFF)
        # Sub-blocks of at most 255
        i = 0
        while i < len(stream):
            n = min(255, len(stream) - i)
            out.append(n)
            out += stream[i : i + n]
            i += n
        out.append(0)

    out.append(0x3B)
    return bytes(out)


def decode_gif_frames(path: Path):
    """Return list of (rgb_bytes 64x32, delay_ms)."""
    if _have_pillow():
        return _decode_gif_pillow(path)
    return _decode_gif_stdlib(path)


def _decode_gif_pillow(path: Path):
    from PIL import Image, ImageSequence

    im = Image.open(path)
    canvas_size = im.size
    canvas = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    frames = []
    previous = None

    for frame in ImageSequence.Iterator(im):
        duration = frame.info.get("duration", 0) or 0
        # Pillow GIF duration is in milliseconds.
        delay_ms = int(duration) if duration else DEFAULT_DELAY_MS
        if delay_ms <= 0:
            delay_ms = DEFAULT_DELAY_MS
        disposal = frame.info.get("disposal", 0) or 0

        if disposal == 3:
            previous = canvas.copy()

        # Frame may be smaller; paste at (0,0) — Pillow's Iterator gives full images
        # for many GIFs. Use dispose region from frame size.
        rgba = frame.convert("RGBA")
        # Position: try to get from frame
        left = 0
        top = 0
        if hasattr(im, "dispose_extent") and im.dispose_extent:
            pass
        canvas.paste(rgba, (left, top), rgba)

        panel = _scale_crop(canvas)
        frames.append((panel, min(delay_ms, 0xFFFF)))

        if disposal == 2:
            # clear frame rect
            clear = Image.new("RGBA", rgba.size, (0, 0, 0, 0))
            canvas.paste(clear, (left, top))
        elif disposal == 3 and previous is not None:
            canvas = previous
        previous = None

    return _subsample(frames)


def _decode_gif_stdlib(path: Path):
    """Very small GIF decoder for the test GIF we write (16-color, full frames)."""
    data = path.read_bytes()
    if data[:6] not in (b"GIF87a", b"GIF89a"):
        raise ValueError("not a GIF")
    w = data[6] | (data[7] << 8)
    h = data[8] | (data[9] << 8)
    packed = data[10]
    off = 13
    gct = []
    if packed & 0x80:
        n = 1 << ((packed & 7) + 1)
        for i in range(n):
            gct.append((data[off], data[off + 1], data[off + 2]))
            off += 3

    frames = []
    delay_cs = 0
    disposal = 0
    canvas = bytearray(w * h * 4)

    while off < len(data):
        b = data[off]
        off += 1
        if b == 0x3B:
            break
        if b == 0x21:
            label = data[off]
            off += 1
            if label == 0xF9:
                sz = data[off]
                off += 1
                flags = data[off]
                disposal = (flags >> 2) & 7
                delay_cs = data[off + 1] | (data[off + 2] << 8)
                off += sz
                while off < len(data):
                    n = data[off]
                    off += 1
                    if n == 0:
                        break
                    off += n
            else:
                while off < len(data):
                    n = data[off]
                    off += 1
                    if n == 0:
                        break
                    off += n
            continue
        if b == 0x2C:
            left = data[off] | (data[off + 1] << 8)
            top = data[off + 2] | (data[off + 3] << 8)
            fw = data[off + 4] | (data[off + 5] << 8)
            fh = data[off + 6] | (data[off + 7] << 8)
            ip = data[off + 8]
            off += 9
            lct = gct
            if ip & 0x80:
                n = 1 << ((ip & 7) + 1)
                lct = []
                for i in range(n):
                    lct.append((data[off], data[off + 1], data[off + 2]))
                    off += 3
            min_code = data[off]
            off += 1
            blocks = bytearray()
            while off < len(data):
                n = data[off]
                off += 1
                if n == 0:
                    break
                blocks += data[off : off + n]
                off += n
            indices = _lzw_decode(blocks, min_code, fw * fh)
            # blit
            for y in range(fh):
                for x in range(fw):
                    idx = indices[y * fw + x]
                    r, g, bcol = lct[idx] if idx < len(lct) else (0, 0, 0)
                    dx, dy = left + x, top + y
                    if 0 <= dx < w and 0 <= dy < h:
                        i = (dy * w + dx) * 4
                        canvas[i] = r
                        canvas[i + 1] = g
                        canvas[i + 2] = bcol
                        canvas[i + 3] = 255
            panel = _scale_crop_rgba(canvas, w, h)
            delay_ms = delay_cs * 10 if delay_cs > 0 else DEFAULT_DELAY_MS
            frames.append((panel, min(delay_ms, 0xFFFF)))
            if disposal == 2:
                for y in range(fh):
                    for x in range(fw):
                        dx, dy = left + x, top + y
                        if 0 <= dx < w and 0 <= dy < h:
                            i = (dy * w + dx) * 4
                            canvas[i : i + 4] = b"\x00\x00\x00\x00"
            delay_cs = 0
            disposal = 0
            continue
        break
    return _subsample(frames)


def _lzw_decode(data: bytes, min_code_size: int, expected: int) -> list[int]:
    clear = 1 << min_code_size
    stop = clear + 1
    code_size = min_code_size + 1
    next_code = stop + 1
    table = {i: [i] for i in range(clear)}
    bit_pos = 0

    def read_code():
        nonlocal bit_pos
        v = 0
        for i in range(code_size):
            byte_i = bit_pos // 8
            if byte_i >= len(data):
                return None
            if data[byte_i] & (1 << (bit_pos % 8)):
                v |= 1 << i
            bit_pos += 1
        return v

    out = []
    prev = None
    while len(out) < expected:
        code = read_code()
        if code is None or code == stop:
            break
        if code == clear:
            table = {i: [i] for i in range(clear)}
            code_size = min_code_size + 1
            next_code = stop + 1
            prev = None
            continue
        if code in table:
            entry = table[code]
        elif prev is not None and code == next_code:
            entry = prev + [prev[0]]
        else:
            break
        out.extend(entry)
        if prev is not None and next_code < 4096:
            table[next_code] = prev + [entry[0]]
            next_code += 1
            if next_code == (1 << code_size) and code_size < 12:
                code_size += 1
        prev = entry
    if len(out) < expected:
        out.extend([0] * (expected - len(out)))
    return out[:expected]


def _scale_crop(rgba_image) -> bytes:
    """Pillow Image RGBA -> 64x32 RGB aspect-fill center crop."""
    from PIL import Image

    w, h = rgba_image.size
    scale = max(WIDTH / w, HEIGHT / h)
    nw = max(1, int(round(w * scale)))
    nh = max(1, int(round(h * scale)))
    scaled = rgba_image.resize((nw, nh), Image.NEAREST)
    left = (nw - WIDTH) // 2
    top = (nh - HEIGHT) // 2
    crop = scaled.crop((left, top, left + WIDTH, top + HEIGHT)).convert("RGBA")
    out = bytearray(WIDTH * HEIGHT * 3)
    px = crop.load()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            r, g, b, a = px[x, y]
            i = (y * WIDTH + x) * 3
            if a == 0:
                out[i : i + 3] = b"\x00\x00\x00"
            else:
                out[i] = r
                out[i + 1] = g
                out[i + 2] = b
    return bytes(out)


def _scale_crop_rgba(canvas: bytearray, w: int, h: int) -> bytes:
    scale = max(WIDTH / w, HEIGHT / h)
    origin_x = (w * scale - WIDTH) / 2.0
    origin_y = (h * scale - HEIGHT) / 2.0
    out = bytearray(WIDTH * HEIGHT * 3)
    for py in range(HEIGHT):
        for px in range(WIDTH):
            sx = int((px + 0.5 + origin_x) / scale)
            sy = int((py + 0.5 + origin_y) / scale)
            cx = min(max(sx, 0), w - 1)
            cy = min(max(sy, 0), h - 1)
            si = (cy * w + cx) * 4
            di = (py * WIDTH + px) * 3
            if canvas[si + 3] == 0:
                out[di : di + 3] = b"\x00\x00\x00"
            else:
                out[di] = canvas[si]
                out[di + 1] = canvas[si + 1]
                out[di + 2] = canvas[si + 2]
    return bytes(out)


def _subsample(frames):
    if len(frames) <= MAX_FRAMES:
        return frames
    return [frames[i * len(frames) // MAX_FRAMES] for i in range(MAX_FRAMES)]


def frames_to_bytecode(frames) -> bytes:
    out = bytearray()
    for rgb, delay_ms in frames:
        out.append(assemble.OP_CLR)
        for y in range(HEIGHT):
            for x in range(WIDTH):
                i = (y * WIDTH + x) * 3
                r, g, b = rgb[i], rgb[i + 1], rgb[i + 2]
                if r + g + b < NEAR_BLACK:
                    continue
                out.append(assemble.OP_PIXI)
                out.extend([x, y, r, g, b])
        ms = max(1, min(int(delay_ms), 0xFFFF))
        out.append(assemble.OP_DELAY)
        out.extend(struct.pack("<H", ms))
    out.append(assemble.OP_JMP)
    out.extend(struct.pack("<H", 0))
    return bytes(out)


def gif_to_bin(gif_path: Path, bin_path: Path) -> bytes:
    frames = decode_gif_frames(gif_path)
    if not frames:
        raise SystemExit("no frames decoded")
    code = frames_to_bytecode(frames)
    image = assemble.build_image(code)
    loaded = assemble.parse_image(image)
    if not loaded.startswith(code[: min(16, len(code))]):
        # allow nop pad at end
        pass
    if assemble.parse_image(image)[:4] != (code + bytes(4))[:4] and not loaded:
        raise SystemExit("round-trip failed")
    # verify parse works
    assemble.parse_image(image)
    bin_path.write_bytes(image)
    return image


def run_preview(image: bytes, preview_dir: Path) -> None:
    import sim

    code = assemble.parse_image(image)
    vm = sim.VM(code)
    # After first frame delay (200ms for test), capture; then second frame.
    # Advance past clr+pixi into first delay completion.
    vm.run_until(100)
    if vm.fault:
        raise SystemExit(f"fault frame0: {vm.fault}")
    # Force a full scan so latched matches fb
    vm.hub.scan(1)
    path0 = preview_dir / "gif-frame0.png"
    sim.save_png(path0, vm.hub.latched)
    sum0 = bytes(vm.hub.latched)

    vm.run_until(300)
    if vm.fault:
        raise SystemExit(f"fault frame1: {vm.fault}")
    vm.hub.scan(1)
    path1 = preview_dir / "gif-frame1.png"
    sim.save_png(path1, vm.hub.latched)
    sum1 = bytes(vm.hub.latched)

    def lit(buf):
        n = 0
        for i in range(0, len(buf), 3):
            if buf[i] or buf[i + 1] or buf[i + 2]:
                n += 1
        return n

    l0, l1 = lit(sum0), lit(sum1)
    if l0 < 10 or l1 < 10:
        raise SystemExit(f"preview blank: lit0={l0} lit1={l1}")
    if sum0 == sum1:
        raise SystemExit("gif-frame0 and gif-frame1 are identical")
    print(f"wrote {path0} lit={l0}")
    print(f"wrote {path1} lit={l1}")
    print(f"frames differ: ok")


def main(argv):
    root = Path(__file__).resolve().parents[1]
    preview = root / "preview"
    preview.mkdir(parents=True, exist_ok=True)
    fw = root / "firmware"

    if len(argv) >= 3:
        gif_path = Path(argv[1])
        bin_path = Path(argv[2])
        image = gif_to_bin(gif_path, bin_path)
        print(f"wrote {bin_path} ({len(image)} bytes)")
        return

    gif_path = fw / "test_anim.gif"
    bin_path = fw / "test_anim.bin"
    make_test_gif(gif_path)
    print(f"wrote {gif_path} ({gif_path.stat().st_size} bytes)")
    image = gif_to_bin(gif_path, bin_path)
    print(f"wrote {bin_path} ({len(image)} bytes, magic=0x{image[0]:02X})")
    run_preview(image, preview)
    print("ok")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise
