import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Convert an animated GIF into a MatrixEmu ESP32-S3 application image.
/// Frames become clr + pixi + delay bytecode; the image layout matches assemble.py.
enum GIFFirmware {
    static var panelWidth = 64
    static var panelHeight = 32
    static let maxFrames = 60
    static let nearBlack = 24
    static let defaultDelayMs = 100

    struct ConvertError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Build an ESP application image from GIF bytes. Throws on decode failure.
    static func convert(_ data: Data, width: Int = 64, height: Int = 32) throws -> Data {
        panelWidth = max(1, width)
        panelHeight = max(1, height)
        let frames = try decodeAndComposite(data)
        guard !frames.isEmpty else {
            throw ConvertError(message: "GIF has no frames")
        }
        let picked = subsample(frames, limit: maxFrames)
        let code = emitBytecode(picked)
        return ESPImage.build(bytecode: code)
    }

    // MARK: - Frame metadata from the GIF file (offsets, disposal, delay)

    private struct FrameMeta {
        var left: Int
        var top: Int
        var width: Int
        var height: Int
        var delayCs: Int // centiseconds; 0 means missing
        var disposal: Int
    }

    private static func parseFrameMeta(_ data: Data) throws -> (canvasW: Int, canvasH: Int, frames: [FrameMeta]) {
        guard data.count >= 13 else {
            throw ConvertError(message: "GIF is truncated")
        }
        let sig = String(bytes: data[0..<6], encoding: .ascii) ?? ""
        guard sig == "GIF87a" || sig == "GIF89a" else {
            throw ConvertError(message: "not a GIF file")
        }
        let canvasW = Int(data[6]) | (Int(data[7]) << 8)
        let canvasH = Int(data[8]) | (Int(data[9]) << 8)
        let packed = Int(data[10])
        var offset = 13
        if (packed & 0x80) != 0 {
            let gctSize = 3 * (1 << ((packed & 0x07) + 1))
            offset += gctSize
        }

        var frames: [FrameMeta] = []
        var pendingDelay = 0
        var pendingDisposal = 0

        while offset < data.count {
            let block = data[offset]
            offset += 1
            if block == 0x3B { // trailer
                break
            }
            if block == 0x21 { // extension
                guard offset < data.count else { break }
                let label = data[offset]
                offset += 1
                if label == 0xF9 { // graphic control
                    guard offset < data.count else { break }
                    let sz = Int(data[offset])
                    offset += 1
                    if sz >= 4, offset + 4 <= data.count {
                        let flags = Int(data[offset])
                        pendingDisposal = (flags >> 2) & 0x07
                        pendingDelay = Int(data[offset + 1]) | (Int(data[offset + 2]) << 8)
                        offset += sz
                    } else {
                        offset += sz
                    }
                    // sub-block terminator
                    while offset < data.count {
                        let n = Int(data[offset])
                        offset += 1
                        if n == 0 { break }
                        offset += n
                    }
                } else {
                    while offset < data.count {
                        let n = Int(data[offset])
                        offset += 1
                        if n == 0 { break }
                        offset += n
                    }
                }
                continue
            }
            if block == 0x2C { // image descriptor
                guard offset + 9 <= data.count else {
                    throw ConvertError(message: "GIF image descriptor truncated")
                }
                let left = Int(data[offset]) | (Int(data[offset + 1]) << 8)
                let top = Int(data[offset + 2]) | (Int(data[offset + 3]) << 8)
                let w = Int(data[offset + 4]) | (Int(data[offset + 5]) << 8)
                let h = Int(data[offset + 6]) | (Int(data[offset + 7]) << 8)
                let ipacked = Int(data[offset + 8])
                offset += 9
                if (ipacked & 0x80) != 0 {
                    let lctSize = 3 * (1 << ((ipacked & 0x07) + 1))
                    offset += lctSize
                }
                // LZW min code size + sub-blocks
                if offset < data.count { offset += 1 }
                while offset < data.count {
                    let n = Int(data[offset])
                    offset += 1
                    if n == 0 { break }
                    offset += n
                }
                frames.append(FrameMeta(
                    left: left, top: top, width: w, height: h,
                    delayCs: pendingDelay, disposal: pendingDisposal
                ))
                pendingDelay = 0
                pendingDisposal = 0
                continue
            }
            // Unknown block — stop rather than walk into garbage.
            break
        }
        if frames.isEmpty {
            throw ConvertError(message: "GIF has no frames")
        }
        return (canvasW, canvasH, frames)
    }

    // MARK: - Composite + scale

    private struct PanelFrame {
        var rgb: [UInt8] // panelWidth * panelHeight * 3
        var delayMs: Int
    }

    private static func decodeAndComposite(_ data: Data) throws -> [PanelFrame] {
        let (canvasW, canvasH, metas) = try parseFrameMeta(data)
        guard canvasW > 0, canvasH > 0 else {
            throw ConvertError(message: "GIF has an empty canvas")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            throw ConvertError(message: "GIF could not be opened")
        }
        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0 else {
            throw ConvertError(message: "GIF has no frames")
        }
        let count = min(imageCount, metas.count)

        // Top-down RGBA canvas.
        var canvas = [UInt8](repeating: 0, count: canvasW * canvasH * 4)
        var previous: [UInt8]?
        var out: [PanelFrame] = []

        for i in 0..<count {
            let meta = metas[i]
            let delayMs: Int = {
                if meta.delayCs <= 0 { return defaultDelayMs }
                return min(meta.delayCs * 10, 0xFFFF)
            }()

            if meta.disposal == 3 {
                previous = canvas
            }

            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else {
                throw ConvertError(message: "GIF frame \(i) could not be decoded")
            }
            let framePixels = try rgbaBytes(from: cgImage)
            let fw = cgImage.width
            let fh = cgImage.height

            // ImageIO usually returns the frame's own bitmap (fw×fh), not the canvas.
            // Place it at (left, top). If ImageIO returned a full-canvas image, left/top are 0.
            let placeLeft: Int
            let placeTop: Int
            let placeW: Int
            let placeH: Int
            if fw == canvasW && fh == canvasH {
                placeLeft = 0
                placeTop = 0
                placeW = canvasW
                placeH = canvasH
            } else {
                placeLeft = meta.left
                placeTop = meta.top
                placeW = fw
                placeH = fh
            }

            blit(
                src: framePixels, srcW: placeW, srcH: placeH,
                into: &canvas, dstW: canvasW, dstH: canvasH,
                atX: placeLeft, atY: placeTop
            )

            let panel = scaleCropRGB(canvas: canvas, width: canvasW, height: canvasH)
            out.append(PanelFrame(rgb: panel, delayMs: delayMs))

            switch meta.disposal {
            case 2:
                clearRect(
                    &canvas, width: canvasW, height: canvasH,
                    x: placeLeft, y: placeTop, w: placeW, h: placeH
                )
            case 3:
                if let snap = previous {
                    canvas = snap
                }
            default:
                break
            }
            previous = nil
        }
        return out
    }

    private static func rgbaBytes(from image: CGImage) throws -> [UInt8] {
        let w = image.width
        let h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buf,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConvertError(message: "GIF frame rasterizer failed")
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Un-premultiply into straight RGB for compositing over the GIF canvas.
        for i in stride(from: 0, to: buf.count, by: 4) {
            let a = Int(buf[i + 3])
            if a == 0 {
                buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0
            } else if a < 255 {
                buf[i] = UInt8(min(255, Int(buf[i]) * 255 / a))
                buf[i + 1] = UInt8(min(255, Int(buf[i + 1]) * 255 / a))
                buf[i + 2] = UInt8(min(255, Int(buf[i + 2]) * 255 / a))
            }
        }
        return buf
    }

    /// Alpha-over blit of a frame onto the canvas. Transparent source pixels are skipped.
    private static func blit(
        src: [UInt8], srcW: Int, srcH: Int,
        into dst: inout [UInt8], dstW: Int, dstH: Int,
        atX: Int, atY: Int
    ) {
        for y in 0..<srcH {
            let dy = atY + y
            if dy < 0 || dy >= dstH { continue }
            for x in 0..<srcW {
                let dx = atX + x
                if dx < 0 || dx >= dstW { continue }
                let si = (y * srcW + x) * 4
                let a = src[si + 3]
                if a == 0 { continue }
                let di = (dy * dstW + dx) * 4
                if a == 255 {
                    dst[di] = src[si]
                    dst[di + 1] = src[si + 1]
                    dst[di + 2] = src[si + 2]
                    dst[di + 3] = 255
                } else {
                    let aa = Int(a)
                    let inv = 255 - aa
                    dst[di] = UInt8((Int(src[si]) * aa + Int(dst[di]) * inv) / 255)
                    dst[di + 1] = UInt8((Int(src[si + 1]) * aa + Int(dst[di + 1]) * inv) / 255)
                    dst[di + 2] = UInt8((Int(src[si + 2]) * aa + Int(dst[di + 2]) * inv) / 255)
                    dst[di + 3] = UInt8(min(255, aa + Int(dst[di + 3]) * inv / 255))
                }
            }
        }
    }

    private static func clearRect(
        _ canvas: inout [UInt8], width: Int, height: Int,
        x: Int, y: Int, w: Int, h: Int
    ) {
        for yy in max(0, y)..<min(height, y + h) {
            for xx in max(0, x)..<min(width, x + w) {
                let i = (yy * width + xx) * 4
                canvas[i] = 0
                canvas[i + 1] = 0
                canvas[i + 2] = 0
                canvas[i + 3] = 0
            }
        }
    }

    /// Aspect-fill, center-crop to 64×32 RGB.
    private static func scaleCropRGB(canvas: [UInt8], width: Int, height: Int) -> [UInt8] {
        let scale = max(Double(panelWidth) / Double(width), Double(panelHeight) / Double(height))
        let scaledW = Double(width) * scale
        let scaledH = Double(height) * scale
        let originX = (scaledW - Double(panelWidth)) / 2.0
        let originY = (scaledH - Double(panelHeight)) / 2.0
        var out = [UInt8](repeating: 0, count: panelWidth * panelHeight * 3)
        for py in 0..<panelHeight {
            for px in 0..<panelWidth {
                let sx = Int(((Double(px) + 0.5 + originX) / scale).rounded(.down))
                let sy = Int(((Double(py) + 0.5 + originY) / scale).rounded(.down))
                let cx = min(max(sx, 0), width - 1)
                let cy = min(max(sy, 0), height - 1)
                let si = (cy * width + cx) * 4
                let a = Int(canvas[si + 3])
                let di = (py * panelWidth + px) * 3
                if a == 0 {
                    out[di] = 0; out[di + 1] = 0; out[di + 2] = 0
                } else {
                    out[di] = canvas[si]
                    out[di + 1] = canvas[si + 1]
                    out[di + 2] = canvas[si + 2]
                }
            }
        }
        return out
    }

    private static func subsample(_ frames: [PanelFrame], limit: Int) -> [PanelFrame] {
        if frames.count <= limit { return frames }
        return (0..<limit).map { i in frames[i * frames.count / limit] }
    }

    // MARK: - Bytecode

    private static func emitBytecode(_ frames: [PanelFrame]) -> [UInt8] {
        var code = [UInt8]()
        for frame in frames {
            code.append(MatrixMachine.opCLR)
            for y in 0..<panelHeight {
                for x in 0..<panelWidth {
                    let i = (y * panelWidth + x) * 3
                    let r = Int(frame.rgb[i])
                    let g = Int(frame.rgb[i + 1])
                    let b = Int(frame.rgb[i + 2])
                    if r + g + b < nearBlack { continue }
                    code.append(MatrixMachine.opPIXI)
                    code.append(UInt8(x))
                    code.append(UInt8(y))
                    code.append(UInt8(r & 255))
                    code.append(UInt8(g & 255))
                    code.append(UInt8(b & 255))
                }
            }
            let ms = min(max(frame.delayMs, 1), 0xFFFF)
            code.append(MatrixMachine.opDELAY)
            code.append(UInt8(ms & 0xFF))
            code.append(UInt8((ms >> 8) & 0xFF))
        }
        code.append(MatrixMachine.opJMP)
        code.append(0)
        code.append(0)
        return code
    }
}
