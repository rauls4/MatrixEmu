import Foundation

/// Turn painted 64×32 RGB frames into a MatrixEmu animation image.
enum FlipBookFirmware {
    static var width = 64
    static var height = 32
    static let nearBlack = 24
    static let maxFrames = 60

    static func convert(frames: [[UInt8]], delayMs: Int, width panelW: Int = 64, height panelH: Int = 32) -> Data {
        width = max(1, panelW)
        height = max(1, panelH)
        let picked: [[UInt8]]
        if frames.count <= maxFrames {
            picked = frames
        } else {
            picked = (0..<maxFrames).map { i in frames[i * frames.count / maxFrames] }
        }
        var code = [UInt8]()
        let ms = min(max(delayMs, 1), 0xFFFF)
        for frame in picked {
            code.append(MatrixMachine.opCLR)
            let count = min(frame.count, width * height * 3)
            var i = 0
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let r = Int(frame[i])
                    let g = Int(frame[i + 1])
                    let b = Int(frame[i + 2])
                    if r + g + b >= nearBlack {
                        code.append(MatrixMachine.opPIXI)
                        code.append(UInt8(x))
                        code.append(UInt8(y))
                        code.append(UInt8(r & 255))
                        code.append(UInt8(g & 255))
                        code.append(UInt8(b & 255))
                    }
                    i += 3
                    x += 1
                }
                y += 1
            }
            _ = count
            code.append(MatrixMachine.opDELAY)
            code.append(UInt8(ms & 0xFF))
            code.append(UInt8((ms >> 8) & 0xFF))
        }
        if code.isEmpty {
            code.append(MatrixMachine.opCLR)
            code.append(MatrixMachine.opDELAY)
            code.append(contentsOf: [UInt8(100), 0])
        }
        code.append(MatrixMachine.opJMP)
        code.append(0)
        code.append(0)
        return ESPImage.build(bytecode: code)
    }
}
