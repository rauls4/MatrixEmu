#!/usr/bin/env python3
"""Assemble MatrixEmu bytecode into an ESP32-S3 application image.

The on-disk file matches the ESP-IDF / esptool app image layout closely
enough that a random blob is rejected and a real-shaped image is accepted:

  * 8-byte common header, magic byte 0xE9
  * 16-byte extended header (ESP32-S3 chip id 0x0009)
  * segments: uint32 load address, uint32 length, data (length multiple of 4)
  * 0x00 pad so the checksum byte makes the image 16-byte aligned
  * checksum = 0xEF XOR every byte of every segment payload
  * SHA-256 of everything before the digest (hash_appended = 1)

The runnable program is the single segment loaded at 0x3FC00000.
This is NOT an Xtensa image. Bytes in that segment are MatrixEmu bytecode.
"""

import hashlib
import struct
import sys
from pathlib import Path

MAGIC = 0xE9
CHIP_ESP32S3 = 0x0009
PROGRAM_LOAD_ADDR = 0x3FC00000
CHECKSUM_MAGIC = 0xEF
ENTRY_ADDR = PROGRAM_LOAD_ADDR

# Bytecode. Multi-byte immediates are little-endian.
# Register fields are one byte, 0..7. Pixel channels and coordinates
# taken from registers use the low 8 bits.
OP_NOP = 0x00
OP_PIXI = 0x01    # u8 x, y, r, g, b
OP_FILLI = 0x02   # u8 x, y, w, h, r, g, b
OP_DELAY = 0x03   # u16 ms
OP_MILLIS = 0x04  # u8 rd
OP_HALT = 0x05
OP_CLR = 0x06
OP_JMP = 0x10     # u16 absolute bytecode offset
OP_LDI = 0x11     # u8 rd, u32 imm
OP_ADD = 0x12     # u8 rd, u8 rs, i16 imm   rd = rs + imm
OP_BLT = 0x13     # u8 ra, u8 rb, u16 abs   unsigned
OP_BGE = 0x14
OP_BEQ = 0x15
OP_PIXR = 0x16    # u8 rx, ry, rr, rg, rb
OP_FILLR = 0x17   # u8 rx, ry, rw, rh, rr, rg, rb

INSN_SIZE = {
    "nop": 1,
    "pixi": 6,
    "filli": 8,
    "delay": 3,
    "millis": 2,
    "halt": 1,
    "clr": 1,
    "jmp": 3,
    "ldi": 6,
    "add": 5,
    "blt": 5,
    "bge": 5,
    "beq": 5,
    "pixr": 6,
    "fillr": 8,
}


class AssembleError(Exception):
    pass


class ImageError(Exception):
    pass


def _u8(n, what):
    if not 0 <= n <= 255:
        raise AssembleError(f"{what} out of range: {n}")
    return n


def _reg(tok, line_no):
    if len(tok) < 2 or tok[0] not in "rR" or not tok[1:].isdigit():
        raise AssembleError(f"line {line_no}: expected register, got {tok!r}")
    n = int(tok[1:])
    if not 0 <= n <= 7:
        raise AssembleError(f"line {line_no}: register {tok} out of range")
    return n


def _imm(tok, line_no):
    try:
        return int(tok, 0)
    except ValueError as exc:
        raise AssembleError(f"line {line_no}: bad integer {tok!r}") from exc


def _tokenize(line):
    line = line.split(";", 1)[0].strip()
    if not line:
        return []
    return line.replace(",", " ").split()


def _parse_lines(text):
    """Return a list of (line_no, label_or_None, mnemonic_or_None, operands)."""
    items = []
    for line_no, raw in enumerate(text.splitlines(), 1):
        toks = _tokenize(raw)
        if not toks:
            continue
        label = None
        if toks[0].endswith(":"):
            label = toks[0][:-1]
            if not label or any(c.isspace() for c in label):
                raise AssembleError(f"line {line_no}: bad label")
            toks = toks[1:]
            if not toks:
                items.append((line_no, label, None, []))
                continue
        mnem = toks[0].lower()
        if mnem not in INSN_SIZE:
            raise AssembleError(f"line {line_no}: unknown opcode {toks[0]!r}")
        items.append((line_no, label, mnem, toks[1:]))
    return items


def _expect(ops, n, line_no, mnem):
    if len(ops) != n:
        raise AssembleError(
            f"line {line_no}: {mnem} expects {n} operand(s), got {len(ops)}"
        )


def assemble(text):
    items = _parse_lines(text)
    labels = {}
    pc = 0
    for line_no, label, mnem, _ops in items:
        if label is not None:
            if label in labels:
                raise AssembleError(f"line {line_no}: duplicate label {label}")
            labels[label] = pc
        if mnem is not None:
            pc += INSN_SIZE[mnem]

    out = bytearray()
    for line_no, _label, mnem, ops in items:
        if mnem is None:
            continue
        here = len(out)

        def lab_off(tok):
            if tok not in labels:
                raise AssembleError(f"line {line_no}: unknown label {tok}")
            return labels[tok]

        if mnem == "nop":
            _expect(ops, 0, line_no, mnem)
            out.append(OP_NOP)
        elif mnem == "pixi":
            _expect(ops, 5, line_no, mnem)
            vals = [_u8(_imm(t, line_no), "pixi") for t in ops]
            out.append(OP_PIXI)
            out.extend(vals)
        elif mnem == "filli":
            _expect(ops, 7, line_no, mnem)
            vals = [_u8(_imm(t, line_no), "filli") for t in ops]
            out.append(OP_FILLI)
            out.extend(vals)
        elif mnem == "delay":
            _expect(ops, 1, line_no, mnem)
            ms = _imm(ops[0], line_no)
            if not 0 <= ms <= 0xFFFF:
                raise AssembleError(f"line {line_no}: delay out of range")
            out.append(OP_DELAY)
            out.extend(struct.pack("<H", ms))
        elif mnem == "millis":
            _expect(ops, 1, line_no, mnem)
            out.append(OP_MILLIS)
            out.append(_reg(ops[0], line_no))
        elif mnem == "halt":
            _expect(ops, 0, line_no, mnem)
            out.append(OP_HALT)
        elif mnem == "clr":
            _expect(ops, 0, line_no, mnem)
            out.append(OP_CLR)
        elif mnem == "jmp":
            _expect(ops, 1, line_no, mnem)
            off = lab_off(ops[0])
            out.append(OP_JMP)
            out.extend(struct.pack("<H", off))
        elif mnem == "ldi":
            _expect(ops, 2, line_no, mnem)
            imm = _imm(ops[1], line_no) & 0xFFFFFFFF
            out.append(OP_LDI)
            out.append(_reg(ops[0], line_no))
            out.extend(struct.pack("<I", imm))
        elif mnem == "add":
            _expect(ops, 3, line_no, mnem)
            imm = _imm(ops[2], line_no)
            if not -0x8000 <= imm <= 0x7FFF:
                raise AssembleError(f"line {line_no}: add immediate out of i16 range")
            out.append(OP_ADD)
            out.append(_reg(ops[0], line_no))
            out.append(_reg(ops[1], line_no))
            out.extend(struct.pack("<h", imm))
        elif mnem in ("blt", "bge", "beq"):
            _expect(ops, 3, line_no, mnem)
            opc = {"blt": OP_BLT, "bge": OP_BGE, "beq": OP_BEQ}[mnem]
            off = lab_off(ops[2])
            out.append(opc)
            out.append(_reg(ops[0], line_no))
            out.append(_reg(ops[1], line_no))
            out.extend(struct.pack("<H", off))
        elif mnem == "pixr":
            _expect(ops, 5, line_no, mnem)
            out.append(OP_PIXR)
            out.extend(_reg(t, line_no) for t in ops)
        elif mnem == "fillr":
            _expect(ops, 7, line_no, mnem)
            out.append(OP_FILLR)
            out.extend(_reg(t, line_no) for t in ops)
        else:
            raise AssembleError(f"line {line_no}: unhandled {mnem}")
        if len(out) - here != INSN_SIZE[mnem]:
            raise AssembleError(f"line {line_no}: internal size mismatch for {mnem}")
    if len(out) != pc:
        raise AssembleError("internal error: label pass disagreed with encoding")
    return bytes(out), labels


def build_image(bytecode, entry=ENTRY_ADDR, load_addr=PROGRAM_LOAD_ADDR):
    """ESP32-S3 application image containing one RAM segment."""
    code = bytes(bytecode)
    if len(code) % 4:
        code += bytes(OP_NOP for _ in range(4 - (len(code) % 4)))
    if len(code) == 0 or len(code) > 0x100000:
        raise ImageError("program segment length is invalid")

    # flash mode DIO (2); size nibble 5 = 32MB (ESP32-S3-N32R16), speed nibble 0xF = 80MHz
    header = struct.pack("<BBBBI", MAGIC, 1, 2, 0x5F, entry & 0xFFFFFFFF)
    extended = struct.pack(
        "<BBBBHBHH4sB",
        0xEE,          # WP pin disabled
        0, 0, 0,       # SPI pin drive
        CHIP_ESP32S3,
        0,             # min_rev
        0,             # min_rev_full
        0xFFFF,        # max_rev_full
        b"\x00\x00\x00\x00",
        1,             # hash appended
    )
    if len(header) != 8 or len(extended) != 16:
        raise ImageError("header size is not the ESP-IDF layout")
    segment = struct.pack("<II", load_addr & 0xFFFFFFFF, len(code)) + code
    body = header + extended + segment

    checksum = CHECKSUM_MAGIC
    for b in code:
        checksum ^= b
    checksum &= 0xFF
    # esptool append_checksum: skip (15 - len%16) bytes, then write checksum.
    align = 15 - (len(body) % 16)
    image = body + (b"\x00" * align) + bytes([checksum])
    if len(image) % 16 != 0:
        raise ImageError("image was not 16-byte aligned before the digest")
    image += hashlib.sha256(image).digest()
    return image


def parse_image(blob):
    """Return the bytecode segment at 0x3FC00000 or raise ImageError."""
    if len(blob) < 24 or blob[0] != MAGIC:
        raise ImageError("not an ESP32 image (missing 0xE9 header)")
    seg_count = blob[1]
    if not 1 <= seg_count <= 16:
        raise ImageError("not an ESP32 image (bad segment count)")
    chip = struct.unpack_from("<H", blob, 12)[0]
    if chip != CHIP_ESP32S3:
        raise ImageError(f"not an ESP32-S3 image (chip id 0x{chip:04X})")
    hash_flag = blob[23]
    if hash_flag not in (0, 1):
        raise ImageError("not an ESP32 image (bad hash flag)")

    off = 24
    segments = []
    for _ in range(seg_count):
        if off + 8 > len(blob):
            raise ImageError("not an ESP32 image (truncated segment header)")
        addr, length = struct.unpack_from("<II", blob, off)
        off += 8
        if length > 16 * 1024 * 1024 or off + length > len(blob):
            raise ImageError("not an ESP32 image (bad segment length)")
        if length % 4 != 0:
            raise ImageError("not an ESP32 image (segment length is not a multiple of 4)")
        segments.append((addr, blob[off:off + length]))
        off += length

    align = 15 - (off % 16)
    csum_at = off + align
    if csum_at >= len(blob):
        raise ImageError("not an ESP32 image (truncated checksum)")
    expect = CHECKSUM_MAGIC
    for _addr, data in segments:
        for b in data:
            expect ^= b
    expect &= 0xFF
    if blob[csum_at] != expect:
        raise ImageError("not an ESP32 image (checksum mismatch)")
    image_end = csum_at + 1
    if hash_flag == 1:
        if image_end + 32 > len(blob):
            raise ImageError("not an ESP32 image (truncated sha256)")
        digest = hashlib.sha256(blob[:image_end]).digest()
        if blob[image_end:image_end + 32] != digest:
            raise ImageError("not an ESP32 image (sha256 mismatch)")

    programs = [data for addr, data in segments if addr == PROGRAM_LOAD_ADDR]
    if not programs:
        raise ImageError("ESP32 image has no program segment at 0x3FC00000")
    if len(programs) != 1:
        raise ImageError("ESP32 image has more than one segment at 0x3FC00000")
    if not programs[0]:
        raise ImageError("program segment at 0x3FC00000 is empty")
    return programs[0]


def assemble_file(src, dest):
    text = Path(src).read_text(encoding="utf-8")
    code, _labels = assemble(text)
    image = build_image(code)
    # Round-trip so we never write an image this loader would reject.
    loaded = parse_image(image)
    if not loaded.startswith(code):
        raise ImageError("round-trip lost the program bytes")
    Path(dest).write_bytes(image)
    return image


def main(argv):
    src = Path(argv[1]) if len(argv) > 1 else Path(__file__).with_name("demo.asm")
    dest = Path(argv[2]) if len(argv) > 2 else src.with_suffix(".bin")
    image = assemble_file(src, dest)
    code = parse_image(image)
    print(f"wrote {dest} ({len(image)} bytes, bytecode {len(code)} bytes)")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except (AssembleError, ImageError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
