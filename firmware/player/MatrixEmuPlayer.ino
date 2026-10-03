/*
 * MatrixEmuPlayer — Arduino-ESP32 sketch for Waveshare ESP32-S3-RGB-Matrix
 * driving a RGB-Matrix-P3-64x32 (HUB75, 1/16 scan).
 *
 * Flash this sketch ONCE onto the board. Then copy MatrixEmu animation
 * images (animation.bin from the iOS app Share sheet) into LittleFS as
 * /animation.bin, or paste the bytecode into ANIMATION_IMAGE below.
 *
 * The shared file is NOT a stock ESP-IDF / Arduino application image you
 * flash with esptool as firmware. It is an ESP-IDF-shaped container whose
 * segment at load address 0x3FC00000 holds MatrixEmu bytecode. Only this
 * player (or the iOS emulator) executes that bytecode.
 *
 * Board: Waveshare ESP32-S3-RGB-Matrix (ESP32-S3-N32R16)
 * Panel: 64x32, 1/16 scan. E (GPIO9) held low.
 *
 * GPIO map (Waveshare "Confirm the Pins"):
 *   R1 4   G1 5   B1 6   R2 7   G2 15  B2 16
 *   A 18   B 8    C 3    D 42   E 9
 *   CLK 41 LAT 40 OE 2 (active low)
 *
 * Build on a Mac or Linux host (not on the iPhone):
 *   firmware/compile_ino.sh firmware/player/MatrixEmuPlayer.ino \
 *     firmware/player/MatrixEmuPlayer.bin
 * That uses arduino-cli, FQBN esp32:esp32:esp32s3, and writes a real
 * ESP32-S3 application image. It is not a MatrixEmu animation image.
 * For the N32R16 board, set USB CDC on Boot and a LittleFS partition
 * (see the repo README, "Compile an .ino").
 */

#include <Arduino.h>
#include <string.h>

#if defined(BOARD_HAS_PSRAM) || defined(CONFIG_SPIRAM)
// optional
#endif

// Prefer LittleFS animation.bin when present; else use embedded blob.
#if __has_include(<LittleFS.h>)
#include <LittleFS.h>
#define HAS_LITTLEFS 1
#else
#define HAS_LITTLEFS 0
#endif

static const int PIN_R1 = 4;
static const int PIN_G1 = 5;
static const int PIN_B1 = 6;
static const int PIN_R2 = 7;
static const int PIN_G2 = 15;
static const int PIN_B2 = 16;
static const int PIN_A = 18;
static const int PIN_B = 8;
static const int PIN_C = 3;
static const int PIN_D = 42;
static const int PIN_E = 9;
static const int PIN_CLK = 41;
static const int PIN_LAT = 40;
static const int PIN_OE = 2;

static const int WIDTH = 64;
static const int HEIGHT = 32;
static const int PAIRS = 16;

static const uint8_t OP_NOP = 0x00;
static const uint8_t OP_PIXI = 0x01;
static const uint8_t OP_FILLI = 0x02;
static const uint8_t OP_DELAY = 0x03;
static const uint8_t OP_MILLIS = 0x04;
static const uint8_t OP_HALT = 0x05;
static const uint8_t OP_CLR = 0x06;
static const uint8_t OP_JMP = 0x10;
static const uint8_t OP_LDI = 0x11;
static const uint8_t OP_ADD = 0x12;
static const uint8_t OP_BLT = 0x13;
static const uint8_t OP_BGE = 0x14;
static const uint8_t OP_BEQ = 0x15;
static const uint8_t OP_PIXR = 0x16;
static const uint8_t OP_FILLR = 0x17;

static const uint32_t PROGRAM_ADDR = 0x3FC00000UL;
static const uint8_t IMAGE_MAGIC = 0xE9;
static const uint16_t CHIP_ESP32S3 = 0x0009;
static const uint8_t CHECKSUM_MAGIC = 0xEF;

// Tiny built-in animation (clr, red fill bar, delay, jmp 0) so the board
// lights up even with no LittleFS file. Replace by copying animation.bin.
static const uint8_t EMBEDDED_BYTECODE[] = {
  0x06,                         // clr
  0x02, 0, 12, 64, 8, 255, 40, 40,  // filli x=0 y=12 w=64 h=8 r g b
  0x03, 0xF4, 0x01,             // delay 500
  0x06,                         // clr
  0x02, 0, 12, 64, 8, 40, 220, 60,
  0x03, 0xF4, 0x01,
  0x06,
  0x02, 0, 12, 64, 8, 50, 100, 255,
  0x03, 0xF4, 0x01,
  0x10, 0x00, 0x00,             // jmp 0
};

static uint8_t fb[WIDTH * HEIGHT * 3];
static uint8_t *code = nullptr;
static size_t codeLen = 0;
static uint32_t regs[8];
static size_t pc = 0;
static uint32_t timeMs = 0;
static bool halted = false;

static void pinSetup() {
  pinMode(PIN_R1, OUTPUT);
  pinMode(PIN_G1, OUTPUT);
  pinMode(PIN_B1, OUTPUT);
  pinMode(PIN_R2, OUTPUT);
  pinMode(PIN_G2, OUTPUT);
  pinMode(PIN_B2, OUTPUT);
  pinMode(PIN_A, OUTPUT);
  pinMode(PIN_B, OUTPUT);
  pinMode(PIN_C, OUTPUT);
  pinMode(PIN_D, OUTPUT);
  pinMode(PIN_E, OUTPUT);
  pinMode(PIN_CLK, OUTPUT);
  pinMode(PIN_LAT, OUTPUT);
  pinMode(PIN_OE, OUTPUT);
  digitalWrite(PIN_E, LOW);
  digitalWrite(PIN_OE, HIGH); // blank
  digitalWrite(PIN_CLK, LOW);
  digitalWrite(PIN_LAT, LOW);
}

static inline void setAddr(int n) {
  digitalWrite(PIN_A, n & 1);
  digitalWrite(PIN_B, (n >> 1) & 1);
  digitalWrite(PIN_C, (n >> 2) & 1);
  digitalWrite(PIN_D, (n >> 3) & 1);
  digitalWrite(PIN_E, LOW);
}

static void scanOnce() {
  // One full 1/16 refresh of the current framebuffer.
  for (int addr = 0; addr < PAIRS; addr++) {
    digitalWrite(PIN_OE, HIGH);
    int y0 = addr;
    int y1 = addr + 16;
    for (int x = 0; x < WIDTH; x++) {
      int i0 = (y0 * WIDTH + x) * 3;
      int i1 = (y1 * WIDTH + x) * 3;
      digitalWrite(PIN_R1, fb[i0] > 32);
      digitalWrite(PIN_G1, fb[i0 + 1] > 32);
      digitalWrite(PIN_B1, fb[i0 + 2] > 32);
      digitalWrite(PIN_R2, fb[i1] > 32);
      digitalWrite(PIN_G2, fb[i1 + 1] > 32);
      digitalWrite(PIN_B2, fb[i1 + 2] > 32);
      digitalWrite(PIN_CLK, HIGH);
      digitalWrite(PIN_CLK, LOW);
    }
    setAddr(addr);
    digitalWrite(PIN_LAT, HIGH);
    digitalWrite(PIN_LAT, LOW);
    digitalWrite(PIN_OE, LOW);
    delayMicroseconds(40);
  }
  digitalWrite(PIN_OE, HIGH);
}

static void clearFb() {
  memset(fb, 0, sizeof(fb));
}

static void pix(int x, int y, int r, int g, int b) {
  if (x < 0 || y < 0 || x >= WIDTH || y >= HEIGHT) return;
  int i = (y * WIDTH + x) * 3;
  fb[i] = (uint8_t)(r & 255);
  fb[i + 1] = (uint8_t)(g & 255);
  fb[i + 2] = (uint8_t)(b & 255);
}

static void fill(int x, int y, int w, int h, int r, int g, int b) {
  if (w <= 0 || h <= 0) return;
  for (int yy = y; yy < y + h && yy < HEIGHT; yy++) {
    if (yy < 0) continue;
    for (int xx = x; xx < x + w && xx < WIDTH; xx++) {
      if (xx < 0) continue;
      pix(xx, yy, r, g, b);
    }
  }
}

static uint16_t rd16(size_t at) {
  return (uint16_t)code[at] | ((uint16_t)code[at + 1] << 8);
}

static uint32_t rd32(size_t at) {
  return (uint32_t)code[at]
       | ((uint32_t)code[at + 1] << 8)
       | ((uint32_t)code[at + 2] << 16)
       | ((uint32_t)code[at + 3] << 24);
}

static bool take(size_t n, size_t *at) {
  if (pc + n > codeLen) return false;
  *at = pc;
  pc += n;
  return true;
}

static void delayScan(uint16_t ms) {
  // Keep refreshing while waiting so the panel does not blank.
  uint32_t start = millis();
  while ((uint32_t)(millis() - start) < ms) {
    scanOnce();
  }
  timeMs += ms;
}

static void execOne() {
  if (halted || pc >= codeLen) {
    halted = true;
    return;
  }
  size_t at;
  if (!take(1, &at)) { halted = true; return; }
  uint8_t op = code[at];
  switch (op) {
    case OP_NOP:
      break;
    case OP_PIXI: {
      if (!take(5, &at)) { halted = true; return; }
      pix(code[at], code[at + 1], code[at + 2], code[at + 3], code[at + 4]);
      break;
    }
    case OP_FILLI: {
      if (!take(7, &at)) { halted = true; return; }
      fill(code[at], code[at + 1], code[at + 2], code[at + 3],
           code[at + 4], code[at + 5], code[at + 6]);
      break;
    }
    case OP_DELAY: {
      if (!take(2, &at)) { halted = true; return; }
      delayScan(rd16(at));
      break;
    }
    case OP_MILLIS: {
      if (!take(1, &at)) { halted = true; return; }
      uint8_t rd = code[at];
      if (rd < 8) regs[rd] = timeMs;
      break;
    }
    case OP_HALT:
      halted = true;
      clearFb();
      digitalWrite(PIN_OE, HIGH);
      break;
    case OP_CLR:
      clearFb();
      break;
    case OP_JMP: {
      if (!take(2, &at)) { halted = true; return; }
      uint16_t off = rd16(at);
      if (off > codeLen) { halted = true; return; }
      pc = off;
      break;
    }
    case OP_LDI: {
      if (!take(1, &at)) { halted = true; return; }
      uint8_t rd = code[at];
      if (!take(4, &at)) { halted = true; return; }
      if (rd < 8) regs[rd] = rd32(at);
      break;
    }
    case OP_ADD: {
      if (!take(1, &at)) { halted = true; return; }
      uint8_t rd = code[at];
      if (!take(1, &at)) { halted = true; return; }
      uint8_t rs = code[at];
      if (!take(2, &at)) { halted = true; return; }
      int16_t imm = (int16_t)rd16(at);
      if (rd < 8 && rs < 8) regs[rd] = regs[rs] + (int32_t)imm;
      break;
    }
    case OP_BLT:
    case OP_BGE:
    case OP_BEQ: {
      if (!take(1, &at)) { halted = true; return; }
      uint8_t ra = code[at];
      if (!take(1, &at)) { halted = true; return; }
      uint8_t rb = code[at];
      if (!take(2, &at)) { halted = true; return; }
      uint16_t off = rd16(at);
      if (ra > 7 || rb > 7 || off > codeLen) { halted = true; return; }
      bool takeBr = false;
      if (op == OP_BLT) takeBr = regs[ra] < regs[rb];
      else if (op == OP_BGE) takeBr = regs[ra] >= regs[rb];
      else takeBr = regs[ra] == regs[rb];
      if (takeBr) pc = off;
      break;
    }
    case OP_PIXR: {
      if (!take(5, &at)) { halted = true; return; }
      pix(regs[code[at] & 7] & 0xFF, regs[code[at + 1] & 7] & 0xFF,
          regs[code[at + 2] & 7] & 0xFF, regs[code[at + 3] & 7] & 0xFF,
          regs[code[at + 4] & 7] & 0xFF);
      break;
    }
    case OP_FILLR: {
      if (!take(7, &at)) { halted = true; return; }
      fill(regs[code[at] & 7] & 0xFF, regs[code[at + 1] & 7] & 0xFF,
           regs[code[at + 2] & 7] & 0xFF, regs[code[at + 3] & 7] & 0xFF,
           regs[code[at + 4] & 7] & 0xFF, regs[code[at + 5] & 7] & 0xFF,
           regs[code[at + 6] & 7] & 0xFF);
      break;
    }
    default:
      halted = true;
      break;
  }
}

static bool parseImage(const uint8_t *blob, size_t len, const uint8_t **outCode, size_t *outLen) {
  if (len < 24 || blob[0] != IMAGE_MAGIC) return false;
  int segCount = blob[1];
  if (segCount < 1 || segCount > 16) return false;
  uint16_t chip = (uint16_t)blob[12] | ((uint16_t)blob[13] << 8);
  if (chip != CHIP_ESP32S3) return false;
  size_t off = 24;
  const uint8_t *prog = nullptr;
  size_t progLen = 0;
  uint8_t expect = CHECKSUM_MAGIC;
  for (int s = 0; s < segCount; s++) {
    if (off + 8 > len) return false;
    uint32_t addr = (uint32_t)blob[off]
                  | ((uint32_t)blob[off + 1] << 8)
                  | ((uint32_t)blob[off + 2] << 16)
                  | ((uint32_t)blob[off + 3] << 24);
    uint32_t slen = (uint32_t)blob[off + 4]
                  | ((uint32_t)blob[off + 5] << 8)
                  | ((uint32_t)blob[off + 6] << 16)
                  | ((uint32_t)blob[off + 7] << 24);
    off += 8;
    if (slen % 4 != 0 || off + slen > len) return false;
    for (uint32_t i = 0; i < slen; i++) expect ^= blob[off + i];
    if (addr == PROGRAM_ADDR) {
      prog = blob + off;
      progLen = slen;
    }
    off += slen;
  }
  size_t align = 15 - (off % 16);
  size_t csumAt = off + align;
  if (csumAt >= len || blob[csumAt] != expect) return false;
  if (!prog || progLen == 0) return false;
  *outCode = prog;
  *outLen = progLen;
  return true;
}

static uint8_t *loadedImage = nullptr;
static size_t loadedImageLen = 0;

static bool loadFromLittleFS() {
#if HAS_LITTLEFS
  if (!LittleFS.begin(true)) return false;
  File f = LittleFS.open("/animation.bin", "r");
  if (!f) return false;
  size_t n = f.size();
  if (n < 24 || n > 2 * 1024 * 1024) {
    f.close();
    return false;
  }
  uint8_t *buf = (uint8_t *)malloc(n);
  if (!buf) {
    f.close();
    return false;
  }
  if (f.read(buf, n) != (int)n) {
    free(buf);
    f.close();
    return false;
  }
  f.close();
  const uint8_t *prog = nullptr;
  size_t plen = 0;
  if (!parseImage(buf, n, &prog, &plen)) {
    free(buf);
    return false;
  }
  // Keep the whole image alive so prog pointer stays valid; copy bytecode out.
  uint8_t *copy = (uint8_t *)malloc(plen);
  if (!copy) {
    free(buf);
    return false;
  }
  memcpy(copy, prog, plen);
  free(buf);
  if (code && code != EMBEDDED_BYTECODE) free(code);
  code = copy;
  codeLen = plen;
  return true;
#else
  return false;
#endif
}

void setup() {
  pinSetup();
  clearFb();
  Serial.begin(115200);
  delay(200);
  Serial.println("MatrixEmuPlayer");

  if (!loadFromLittleFS()) {
    Serial.println("No /animation.bin — using embedded demo bytecode");
    code = (uint8_t *)EMBEDDED_BYTECODE;
    codeLen = sizeof(EMBEDDED_BYTECODE);
  } else {
    Serial.printf("Loaded animation bytecode (%u bytes)\n", (unsigned)codeLen);
  }
  memset(regs, 0, sizeof(regs));
  pc = 0;
  timeMs = 0;
  halted = false;
}

void loop() {
  if (halted) {
    // Restart loop for looping animations that halt; prefer jmp 0 in images.
    pc = 0;
    halted = false;
    memset(regs, 0, sizeof(regs));
    delay(10);
    return;
  }
  // Run a burst of instructions; delay opcode yields to scanning.
  for (int i = 0; i < 64 && !halted; i++) {
    execOne();
  }
  // Between non-delay ops, still refresh so the last frame stays visible.
  scanOnce();
}
