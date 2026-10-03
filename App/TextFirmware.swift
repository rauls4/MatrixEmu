import Foundation
import SwiftUI

/// Build MatrixEmu ESP animation images from a short message + per-letter colors.
enum TextFirmware {
    enum Effect: String, CaseIterable, Identifiable {
        case staticHold = "Static"
        case slideIn = "Slide in"
        case typewriter = "Typewriter"
        case scroll = "Scroll"
        var id: String { rawValue }
    }

    struct RGB: Equatable {
        var r: UInt8
        var g: UInt8
        var b: UInt8

        static let red = RGB(r: 255, g: 40, b: 40)
        static let orange = RGB(r: 255, g: 140, b: 20)
        static let yellow = RGB(r: 255, g: 220, b: 40)
        static let green = RGB(r: 40, g: 220, b: 60)
        static let cyan = RGB(r: 40, g: 220, b: 220)
        static let blue = RGB(r: 50, g: 100, b: 255)
        static let white = RGB(r: 230, g: 230, b: 235)

        static let palette: [(name: String, color: RGB)] = [
            ("Red", .red),
            ("Orange", .orange),
            ("Yellow", .yellow),
            ("Green", .green),
            ("Cyan", .cyan),
            ("Blue", .blue),
            ("White", .white),
        ]
    }

    /// 5×7 glyphs, bit 0 = leftmost column of each row byte (low 5 bits used).
    /// At least one blank column is added between letters when laying out.
    private static let fontW = 5
    private static let fontH = 7
    private static let letterGap = 1
    private static var panelW = 64
    private static var panelH = 32

    private static let glyphs: [Character: [UInt8]] = [
        " ": [0, 0, 0, 0, 0, 0, 0],
        "A": [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        "B": [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
        "C": [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
        "D": [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
        "E": [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
        "F": [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
        "G": [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E],
        "H": [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        "I": [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
        "J": [0x01, 0x01, 0x01, 0x01, 0x11, 0x11, 0x0E],
        "K": [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
        "L": [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
        "M": [0x11, 0x1B, 0x15, 0x11, 0x11, 0x11, 0x11],
        "N": [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11],
        "O": [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        "P": [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
        "Q": [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
        "R": [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
        "S": [0x0E, 0x11, 0x10, 0x0E, 0x01, 0x11, 0x0E],
        "T": [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
        "U": [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        "V": [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
        "W": [0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11],
        "X": [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
        "Y": [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
        "Z": [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
        "0": [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
        "1": [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
        "2": [0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F],
        "3": [0x0E, 0x11, 0x01, 0x06, 0x01, 0x11, 0x0E],
        "4": [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
        "5": [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
        "6": [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
        "7": [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        "8": [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
        "9": [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
        "!": [0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04],
        "?": [0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04],
        ".": [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04],
        ",": [0x00, 0x00, 0x00, 0x00, 0x04, 0x04, 0x08],
        ":": [0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00],
        "-": [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00],
        "+": [0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00],
        "'": [0x04, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00],
        "\"": [0x0A, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00],
    ]

    /// Build an ESP animation image. Empty / whitespace-only text returns nil (caller keeps firmware).
    static func convert(text: String, colors: [RGB], defaultColor: RGB, effect: Effect, width: Int = 64, height: Int = 32) -> Data? {
        panelW = max(1, width)
        panelH = max(1, height)
        let chars = Array(text)
        guard chars.contains(where: { !$0.isWhitespace }) else { return nil }
        let letterColors: [RGB] = chars.enumerated().map { i, _ in
            i < colors.count ? colors[i] : defaultColor
        }
        let code: [UInt8]
        switch effect {
        case .staticHold:
            code = emitStatic(chars: chars, colors: letterColors)
        case .slideIn:
            code = emitSlideIn(chars: chars, colors: letterColors)
        case .typewriter:
            code = emitTypewriter(chars: chars, colors: letterColors)
        case .scroll:
            code = emitScroll(chars: chars, colors: letterColors)
        }
        return ESPImage.build(bytecode: code)
    }

    // MARK: - Layout

    private static func textPixelWidth(_ count: Int) -> Int {
        if count == 0 { return 0 }
        return count * fontW + max(0, count - 1) * letterGap
    }

    private static func baseY() -> Int { (panelH - fontH) / 2 }

    private static func drawText(
        into fb: inout [UInt8],
        chars: [Character],
        colors: [RGB],
        originX: Int
    ) {
        var x = originX
        let y0 = baseY()
        for (i, ch) in chars.enumerated() {
            let key = Character(ch.uppercased())
            let rows = glyphs[key] ?? glyphs["?"]!
            let color = i < colors.count ? colors[i] : .white
            for row in 0..<fontH {
                let bits = rows[row]
                for col in 0..<fontW {
                    if (bits & (0x10 >> col)) == 0 { continue }
                    let px = x + col
                    let py = y0 + row
                    guard px >= 0, px < panelW, py >= 0, py < panelH else { continue }
                    let di = (py * panelW + px) * 3
                    fb[di] = color.r
                    fb[di + 1] = color.g
                    fb[di + 2] = color.b
                }
            }
            x += fontW + letterGap
        }
    }

    private static func emitFrame(_ fb: [UInt8], delayMs: Int, into code: inout [UInt8]) {
        code.append(MatrixMachine.opCLR)
        for y in 0..<panelH {
            for x in 0..<panelW {
                let i = (y * panelW + x) * 3
                let r = Int(fb[i]), g = Int(fb[i + 1]), b = Int(fb[i + 2])
                if r + g + b < 24 { continue }
                code.append(MatrixMachine.opPIXI)
                code.append(UInt8(x))
                code.append(UInt8(y))
                code.append(UInt8(r))
                code.append(UInt8(g))
                code.append(UInt8(b))
            }
        }
        let ms = min(max(delayMs, 1), 0xFFFF)
        code.append(MatrixMachine.opDELAY)
        code.append(UInt8(ms & 0xFF))
        code.append(UInt8((ms >> 8) & 0xFF))
    }

    private static func blankFB() -> [UInt8] {
        [UInt8](repeating: 0, count: panelW * panelH * 3)
    }

    private static func centeredOrigin(for count: Int) -> Int {
        let tw = textPixelWidth(count)
        return (panelW - tw) / 2
    }

    // MARK: - Effects

    private static func emitStatic(chars: [Character], colors: [RGB]) -> [UInt8] {
        var code = [UInt8]()
        var fb = blankFB()
        let ox = centeredOrigin(for: chars.count)
        // If wider than panel, scroll continuously instead of clipping.
        if textPixelWidth(chars.count) > panelW {
            return emitScroll(chars: chars, colors: colors)
        }
        drawText(into: &fb, chars: chars, colors: colors, originX: ox)
        emitFrame(fb, delayMs: 1000, into: &code)
        code.append(MatrixMachine.opJMP)
        code.append(0)
        code.append(0)
        return code
    }

    private static func emitSlideIn(chars: [Character], colors: [RGB]) -> [UInt8] {
        var code = [UInt8]()
        let tw = textPixelWidth(chars.count)
        let finalX = tw > panelW ? 0 : centeredOrigin(for: chars.count)
        let startX = panelW
        // Slide from right to finalX, then hold, then loop.
        var x = startX
        while x > finalX {
            var fb = blankFB()
            drawText(into: &fb, chars: chars, colors: colors, originX: x)
            emitFrame(fb, delayMs: 40, into: &code)
            x -= 2
        }
        var fb = blankFB()
        drawText(into: &fb, chars: chars, colors: colors, originX: finalX)
        emitFrame(fb, delayMs: 1200, into: &code)
        // If still wider than panel after slide, continue as marquee from finalX.
        if tw > panelW {
            var sx = finalX
            let end = -(tw + 2)
            while sx > end {
                var f2 = blankFB()
                drawText(into: &f2, chars: chars, colors: colors, originX: sx)
                emitFrame(f2, delayMs: 40, into: &code)
                sx -= 1
            }
        }
        code.append(MatrixMachine.opJMP)
        code.append(0)
        code.append(0)
        return code
    }

    private static func emitTypewriter(chars: [Character], colors: [RGB]) -> [UInt8] {
        var code = [UInt8]()
        let tw = textPixelWidth(chars.count)
        if tw > panelW {
            // Reveal while scrolling so nothing is permanently clipped.
            return emitScroll(chars: chars, colors: colors)
        }
        let ox = centeredOrigin(for: chars.count)
        for n in 1...chars.count {
            var fb = blankFB()
            let slice = Array(chars.prefix(n))
            let cols = Array(colors.prefix(n))
            drawText(into: &fb, chars: slice, colors: cols, originX: ox)
            emitFrame(fb, delayMs: 120, into: &code)
        }
        var fb = blankFB()
        drawText(into: &fb, chars: chars, colors: colors, originX: ox)
        emitFrame(fb, delayMs: 1500, into: &code)
        code.append(MatrixMachine.opJMP)
        code.append(0)
        code.append(0)
        return code
    }

    private static func emitScroll(chars: [Character], colors: [RGB]) -> [UInt8] {
        var code = [UInt8]()
        let tw = textPixelWidth(chars.count)
        // Start just off the right edge; end when the last pixel has left the left edge.
        var x = panelW
        let end = -(tw + 1)
        while x >= end {
            var fb = blankFB()
            drawText(into: &fb, chars: chars, colors: colors, originX: x)
            emitFrame(fb, delayMs: 50, into: &code)
            x -= 1
        }
        code.append(MatrixMachine.opJMP)
        code.append(0)
        code.append(0)
        return code
    }
}
