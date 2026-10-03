import SwiftUI

/// How the native framebuffer is drawn. The buffer itself is not rotated or resized.
enum PanelRotation: Int, CaseIterable, Identifiable, Hashable {
    case deg0 = 0
    case deg90 = 90
    case deg180 = 180
    case deg270 = 270

    var id: Int { rawValue }
    var label: String { "\(rawValue)°" }

    /// On-screen columns after this turn. 90 and 270 swap the controller axes.
    func displayWidth(nativeWidth: Int, nativeHeight: Int) -> Int {
        switch self {
        case .deg90, .deg270: return max(nativeHeight, 1)
        case .deg0, .deg180: return max(nativeWidth, 1)
        }
    }

    func displayHeight(nativeWidth: Int, nativeHeight: Int) -> Int {
        switch self {
        case .deg90, .deg270: return max(nativeWidth, 1)
        case .deg0, .deg180: return max(nativeHeight, 1)
        }
    }
}

/// Round LEDs on a black bezel. One Canvas, not a view per pixel.
struct LEDPanelView: View {
    var rgb: [UInt8]
    var width: Int
    var height: Int
    var rotation: PanelRotation = .deg0

    var body: some View {
        Canvas { context, size in
            let nativeW = max(width, 1)
            let nativeH = max(height, 1)
            let cols = rotation.displayWidth(nativeWidth: nativeW, nativeHeight: nativeH)
            let rows = rotation.displayHeight(nativeWidth: nativeW, nativeHeight: nativeH)
            let bezel = min(size.width, size.height) * 0.035
            let well = CGRect(x: bezel, y: bezel, width: size.width - bezel * 2, height: size.height - bezel * 2)
            let pitch = min(well.width / CGFloat(cols), well.height / CGFloat(rows))
            let gridW = pitch * CGFloat(cols)
            let gridH = pitch * CGFloat(rows)
            let originX = well.minX + (well.width - gridW) / 2
            let originY = well.minY + (well.height - gridH) / 2
            let radius = pitch * 0.36

            let shell = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 18, style: .continuous)
            context.fill(shell, with: .color(.black))

            for y in 0..<nativeH {
                for x in 0..<nativeW {
                    let i = (y * nativeW + x) * 3
                    let r = i + 2 < rgb.count ? rgb[i] : 0
                    let g = i + 2 < rgb.count ? rgb[i + 1] : 0
                    let b = i + 2 < rgb.count ? rgb[i + 2] : 0
                    let (dx, dy) = displayPoint(x: x, y: y, nativeW: nativeW, nativeH: nativeH)
                    let cx = originX + (CGFloat(dx) + 0.5) * pitch
                    let cy = originY + (CGFloat(dy) + 0.5) * pitch
                    let dot = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
                    if r == 0 && g == 0 && b == 0 {
                        context.stroke(
                            Path(ellipseIn: dot),
                            with: .color(Color(white: 0.22)),
                            lineWidth: max(0.6, pitch * 0.06)
                        )
                    } else {
                        let color = Color(
                            red: Double(r) / 255,
                            green: Double(g) / 255,
                            blue: Double(b) / 255
                        )
                        let glowR = radius + pitch * 0.16
                        let glow = CGRect(x: cx - glowR, y: cy - glowR, width: glowR * 2, height: glowR * 2)
                        context.fill(Path(ellipseIn: glow), with: .color(color.opacity(0.35)))
                        context.fill(Path(ellipseIn: dot), with: .color(color))
                        let hot = radius * 0.28
                        let hotRect = CGRect(x: cx - hot, y: cy - hot - radius * 0.18, width: hot * 2, height: hot * 2)
                        context.fill(Path(ellipseIn: hotRect), with: .color(Color.white.opacity(0.35)))
                    }
                }
            }
        }
        .accessibilityLabel("\(width) by \(height) LED matrix, rotated \(rotation.rawValue) degrees")
    }

    /// Native pixel (x, y) to on-screen column and row. Clockwise.
    private func displayPoint(x: Int, y: Int, nativeW: Int, nativeH: Int) -> (Int, Int) {
        switch rotation {
        case .deg0:
            return (x, y)
        case .deg90:
            return (nativeH - 1 - y, x)
        case .deg180:
            return (nativeW - 1 - x, nativeH - 1 - y)
        case .deg270:
            return (y, nativeW - 1 - x)
        }
    }
}
