import Foundation

/// Waveshare ESP32-S3-RGB-Matrix HUB75 wiring.
/// Source: https://docs.waveshare.com/ESP32-Peripheral-Tutorials/Display/LED-Matrix
/// section "Confirm the Pins" (ESP32-S3-RGB-Matrix driver board).
///
/// The attached panel is a Waveshare RGB-Matrix-P3-64x32: 64×32, 1/16 scan.
/// That panel uses A–D only. E is present on the driver (GPIO9) and is held low.
enum BoardPins {
    static let product = "ESP32-S3-RGB-Matrix"
    static let panel = "RGB-Matrix-P3-64x32"
    static let r1 = 4
    static let g1 = 5
    static let b1 = 6
    static let r2 = 7
    static let g2 = 15
    static let b2 = 16
    static let a = 18
    static let b = 8
    static let c = 3
    static let d = 42
    static let e = 9
    static let clk = 41
    static let lat = 40
    static let oe = 2
}

/// Framebuffer plus a scan model for the selected controller.
///
/// Firmware does not bitbang GPIO. PIX and FILL write `fb`. What gets copied
/// into `latched` depends on the controller: HUB75 row pairs, a monochrome
/// MAX7219 chain, or a WS2812 frame copy. This is not every LED driver.
enum MatrixController: String, CaseIterable, Identifiable {
    case waveshare
    case hub75_64x32
    case hub75_64x64
    case max7219x4
    case ws2812_8
    case ws2812_16

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waveshare: return "Waveshare ESP32-S3-RGB-Matrix"
        case .hub75_64x32: return "Generic HUB75"
        case .hub75_64x64: return "Generic HUB75"
        case .max7219x4: return "MAX7219 / FC-16"
        case .ws2812_8: return "WS2812 / NeoPixel"
        case .ws2812_16: return "WS2812 / NeoPixel"
        }
    }

    var subtitle: String {
        switch self {
        case .waveshare:
            return "RGB-Matrix-P3-64x32 · HUB75 1/16 · 64×32 · E held low"
        case .hub75_64x32:
            return "64×32 · 1/16 scan · not the Waveshare pin map"
        case .hub75_64x64:
            return "64×64 · 1/32 scan · address A–E"
        case .max7219x4:
            return "Four 8×8 modules · 32×8 · monochrome amber"
        case .ws2812_8:
            return "8×8 · one RGB LED per pixel · no row mux"
        case .ws2812_16:
            return "16×16 · one RGB LED per pixel · no row mux"
        }
    }

    var width: Int {
        switch self {
        case .waveshare, .hub75_64x32, .hub75_64x64: return 64
        case .max7219x4: return 32
        case .ws2812_8: return 8
        case .ws2812_16: return 16
        }
    }

    var height: Int {
        switch self {
        case .waveshare, .hub75_64x32: return 32
        case .hub75_64x64: return 64
        case .max7219x4: return 8
        case .ws2812_8: return 8
        case .ws2812_16: return 16
        }
    }

    /// HUB75 row pairs, or nil when the panel is not HUB75.
    var hubPairs: Int? {
        switch self {
        case .waveshare, .hub75_64x32: return 16
        case .hub75_64x64: return 32
        case .max7219x4, .ws2812_8, .ws2812_16: return nil
        }
    }

    var usesAddressE: Bool { self == .hub75_64x64 }
    var monochrome: Bool { self == .max7219x4 }

    var pinNote: String {
        switch self {
        case .waveshare:
            return "R1 GPIO\(BoardPins.r1)  G1 \(BoardPins.g1)  B1 \(BoardPins.b1)  R2 \(BoardPins.r2)  G2 \(BoardPins.g2)  B2 \(BoardPins.b2)\nA \(BoardPins.a)  B \(BoardPins.b)  C \(BoardPins.c)  D \(BoardPins.d)  E \(BoardPins.e) held low  CLK \(BoardPins.clk)  LAT \(BoardPins.lat)  OE \(BoardPins.oe)"
        case .hub75_64x32:
            return "Generic 64×32 HUB75, 1/16 scan (A–D). Pins are not the Waveshare map. The board player sketch is still the Waveshare 64×32 build."
        case .hub75_64x64:
            return "Generic 64×64 HUB75, 1/32 scan. Address E selects the extra 16 rows. Not the Waveshare 64×32 player."
        case .max7219x4:
            return "Four MAX7219 8×8 modules in a row (32×8). Lit pixels are shown amber. RGB artwork is thresholded. Not HUB75."
        case .ws2812_8, .ws2812_16:
            return "WS2812 chain, row-major, one LED per pixel. No HUB75 latch. The Waveshare player sketch does not drive this panel."
        }
    }

    func status(clock: String, running: Bool, speed: Int, addr: Int, oeBlanked: Bool, halted: Bool) -> String {
        if halted {
            switch self {
            case .ws2812_8, .ws2812_16:
                return "\(clock)  halted"
            case .max7219x4:
                return "\(clock)  halted  blanked"
            default:
                return "\(clock)  halted  OE blank"
            }
        }
        let run = running ? "run" : "paused"
        switch self {
        case .waveshare, .hub75_64x32:
            let oe = oeBlanked ? "OE blank" : "OE lit"
            return "\(clock)  \(run)  \(speed)x  ABCD \(addr)  E low  \(oe)"
        case .hub75_64x64:
            let oe = oeBlanked ? "OE blank" : "OE lit"
            let e = (addr & 16) != 0 ? "E 1" : "E 0"
            return "\(clock)  \(run)  \(speed)x  ABCDE \(addr)  \(e)  \(oe)"
        case .max7219x4:
            return "\(clock)  \(run)  \(speed)x  MAX7219 ×4"
        case .ws2812_8, .ws2812_16:
            return "\(clock)  \(run)  \(speed)x  WS2812"
        }
    }
}

struct Hub75Scan {
    var controller: MatrixController
    var width: Int
    var height: Int
    static let msPerFrame = 1.0

    var fb: [UInt8]
    var latched: [UInt8]
    var addr = 0
    var slots = 0
    var oeHigh = true
    var lat = false
    var clk = false
    var e = false

    init(controller: MatrixController = .waveshare) {
        self.controller = controller
        self.width = controller.width
        self.height = controller.height
        let n = controller.width * controller.height * 3
        self.fb = [UInt8](repeating: 0, count: n)
        self.latched = [UInt8](repeating: 0, count: n)
    }

    mutating func reset() {
        let n = width * height * 3
        fb = [UInt8](repeating: 0, count: n)
        latched = [UInt8](repeating: 0, count: n)
        addr = 0
        slots = 0
        oeHigh = true
        lat = false
        clk = false
        e = false
    }

    mutating func clearFramebuffer() {
        fb = [UInt8](repeating: 0, count: fb.count)
    }

    mutating func clearLatched() {
        latched = [UInt8](repeating: 0, count: latched.count)
        oeHigh = true
    }

    mutating func pixel(x: Int, y: Int, r: Int, g: Int, b: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = (y * width + x) * 3
        fb[i] = UInt8(r & 255)
        fb[i + 1] = UInt8(g & 255)
        fb[i + 2] = UInt8(b & 255)
    }

    mutating func fill(x: Int, y: Int, w: Int, h: Int, r: Int, g: Int, b: Int) {
        if w <= 0 || h <= 0 { return }
        for yy in y..<(y + h) {
            if yy >= height { break }
            if yy < 0 { continue }
            for xx in x..<(x + w) {
                if xx >= width { break }
                if xx < 0 { continue }
                pixel(x: xx, y: yy, r: r, g: g, b: b)
            }
        }
    }

    private mutating func copyRow(_ y: Int) {
        guard y >= 0, y < height else { return }
        let base = y * width * 3
        let end = base + width * 3
        latched.replaceSubrange(base..<end, with: fb[base..<end])
    }

    mutating func latchPair(_ n: Int) {
        oeHigh = true
        lat = false
        let pairs = controller.hubPairs ?? 16
        let upper = n % pairs
        let lower = upper + pairs
        for _ in 0..<width {
            clk = false
            clk = true
        }
        clk = false
        copyRow(upper)
        if lower < height { copyRow(lower) }
        lat = true
        lat = false
        addr = upper
        e = controller.usesAddressE && (upper & 16) != 0
        oeHigh = false
    }

    mutating func commitAll() {
        if controller.monochrome {
            var out = fb
            var i = 0
            while i + 2 < out.count {
                let lit = Int(out[i]) + Int(out[i + 1]) + Int(out[i + 2]) >= 24
                out[i] = lit ? 255 : 0
                out[i + 1] = lit ? 140 : 0
                out[i + 2] = lit ? 20 : 0
                i += 3
            }
            latched = out
        } else {
            latched = fb
        }
        oeHigh = false
        e = false
    }

    mutating func scan(ms: Double) {
        if ms <= 0 { return }
        if controller.hubPairs == nil {
            if ms >= Self.msPerFrame { commitAll() }
            oeHigh = false
            return
        }
        let pairs = controller.hubPairs ?? 16
        let steps = Int(ms / Self.msPerFrame * Double(pairs))
        if steps <= 0 { return }
        if steps >= pairs {
            commitAll()
        } else {
            for i in 0..<steps {
                latchPair((slots + i) % pairs)
            }
        }
        slots += steps
        addr = (slots - 1) % pairs
        oeHigh = false
        if controller.usesAddressE {
            e = (addr & 16) != 0
        } else {
            e = false
        }
    }
}
