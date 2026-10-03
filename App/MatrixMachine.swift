import Combine
import Foundation

/// Bytecode VM for the segment at 0x3FC00000.
/// Opcodes match firmware/assemble.py. This is not an Xtensa core.
final class MatrixMachine {
    static let opNOP: UInt8 = 0x00
    static let opPIXI: UInt8 = 0x01
    static let opFILLI: UInt8 = 0x02
    static let opDELAY: UInt8 = 0x03
    static let opMILLIS: UInt8 = 0x04
    static let opHALT: UInt8 = 0x05
    static let opCLR: UInt8 = 0x06
    static let opJMP: UInt8 = 0x10
    static let opLDI: UInt8 = 0x11
    static let opADD: UInt8 = 0x12
    static let opBLT: UInt8 = 0x13
    static let opBGE: UInt8 = 0x14
    static let opBEQ: UInt8 = 0x15
    static let opPIXR: UInt8 = 0x16
    static let opFILLR: UInt8 = 0x17

    private(set) var code: [UInt8] = []
    private(set) var pc = 0
    private(set) var regs = [UInt32](repeating: 0, count: 8)
    private(set) var timeMs = 0.0
    private var delayLeft = 0.0
    private(set) var halted = false
    private(set) var fault: String?
    private var burst = 0
    private(set) var millisReads = 0
    var hub = Hub75Scan()

    func setPanel(_ controller: MatrixController) {
        let code = self.code
        let pc = self.pc
        let regs = self.regs
        let timeMs = self.timeMs
        let halted = self.halted
        hub = Hub75Scan(controller: controller)
        self.code = code
        self.pc = pc
        self.regs = regs
        self.timeMs = timeMs
        self.halted = halted
    }

    func load(_ program: [UInt8]) {
        code = program
        pc = 0
        regs = [UInt32](repeating: 0, count: 8)
        timeMs = 0
        delayLeft = 0
        halted = false
        fault = nil
        burst = 0
        millisReads = 0
        hub.reset()
    }

    func advance(ms budget: Double) {
        if halted || fault != nil { return }
        var left = budget
        while left > 0 {
            if delayLeft > 0 {
                let step = min(left, delayLeft)
                hub.scan(ms: step)
                delayLeft -= step
                timeMs += step
                left -= step
                burst = 0
                continue
            }
            if !execOne() { break }
        }
    }

    private func execOne() -> Bool {
        do {
            if pc >= code.count {
                throw VMFault("program counter ran off the segment")
            }
            burst += 1
            if burst > 100_000 {
                throw VMFault("program did not delay or halt")
            }
            let op = try take(1)[0]
            switch op {
            case Self.opNOP:
                return true
            case Self.opPIXI:
                let a = try take(5)
                hub.pixel(x: Int(a[0]), y: Int(a[1]), r: Int(a[2]), g: Int(a[3]), b: Int(a[4]))
                return true
            case Self.opFILLI:
                let a = try take(7)
                hub.fill(
                    x: Int(a[0]), y: Int(a[1]), w: Int(a[2]), h: Int(a[3]),
                    r: Int(a[4]), g: Int(a[5]), b: Int(a[6])
                )
                return true
            case Self.opDELAY:
                let raw = try take(2)
                delayLeft = Double(UInt16(raw[0]) | (UInt16(raw[1]) << 8))
                return true
            case Self.opMILLIS:
                let rd = try reg(try take(1)[0])
                regs[rd] = UInt32(truncatingIfNeeded: Int64(timeMs))
                millisReads += 1
                return true
            case Self.opHALT:
                halted = true
                hub.clearLatched()
                hub.oeHigh = true
                return false
            case Self.opCLR:
                hub.clearFramebuffer()
                return true
            case Self.opJMP:
                let raw = try take(2)
                let off = Int(UInt16(raw[0]) | (UInt16(raw[1]) << 8))
                if off > code.count {
                    throw VMFault("jump target \(off) is outside the segment")
                }
                pc = off
                return true
            case Self.opLDI:
                let rd = try reg(try take(1)[0])
                let raw = try take(4)
                regs[rd] = UInt32(raw[0])
                    | (UInt32(raw[1]) << 8)
                    | (UInt32(raw[2]) << 16)
                    | (UInt32(raw[3]) << 24)
                return true
            case Self.opADD:
                let rd = try reg(try take(1)[0])
                let rs = try reg(try take(1)[0])
                let raw = try take(2)
                let imm = Int16(bitPattern: UInt16(raw[0]) | (UInt16(raw[1]) << 8))
                let delta = UInt32(bitPattern: Int32(imm))
                regs[rd] = regs[rs] &+ delta
                return true
            case Self.opBLT, Self.opBGE, Self.opBEQ:
                let ra = try reg(try take(1)[0])
                let rb = try reg(try take(1)[0])
                let raw = try take(2)
                let off = Int(UInt16(raw[0]) | (UInt16(raw[1]) << 8))
                if off > code.count {
                    throw VMFault("branch target \(off) is outside the segment")
                }
                let a = regs[ra]
                let b = regs[rb]
                let take: Bool
                if op == Self.opBLT { take = a < b }
                else if op == Self.opBGE { take = a >= b }
                else { take = a == b }
                if take { pc = off }
                return true
            case Self.opPIXR:
                let a = try take(5)
                hub.pixel(
                    x: try low8(a[0]), y: try low8(a[1]),
                    r: try low8(a[2]), g: try low8(a[3]), b: try low8(a[4])
                )
                return true
            case Self.opFILLR:
                let a = try take(7)
                hub.fill(
                    x: try low8(a[0]), y: try low8(a[1]),
                    w: try low8(a[2]), h: try low8(a[3]),
                    r: try low8(a[4]), g: try low8(a[5]), b: try low8(a[6])
                )
                return true
            default:
                throw VMFault(String(format: "invalid opcode 0x%02X at pc %d", op, pc - 1))
            }
        } catch let error as VMFault {
            fault = error.message
            halted = true
            return false
        } catch {
            fault = error.localizedDescription
            halted = true
            return false
        }
    }

    private func take(_ n: Int) throws -> [UInt8] {
        if pc + n > code.count {
            throw VMFault("truncated instruction at pc \(pc)")
        }
        let slice = Array(code[pc..<(pc + n)])
        pc += n
        return slice
    }

    private func reg(_ value: UInt8) throws -> Int {
        if value > 7 {
            throw VMFault("bad register r\(value) at pc \(pc)")
        }
        return Int(value)
    }

    private func low8(_ index: UInt8) throws -> Int {
        Int(regs[try reg(index)] & 0xFF)
    }
}

private struct VMFault: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor
final class EmulatorModel: ObservableObject {
    @Published var frame: [UInt8]
    @Published var running = true
    @Published var speed = 1
    @Published var firmwareName = "demo.bin"
    @Published var errorText: String?
    @Published var virtualMs = 0.0
    @Published var halted = false
    @Published var scanAddr = 0
    @Published var oeBlanked = true
    @Published var controller: MatrixController = .waveshare
    /// Drawing rotation only. The framebuffer stays the controller's native size.
    @Published var rotation: PanelRotation = .deg0
    @Published var muted = false

    private let machine = MatrixMachine()
    private let audio = PanelAudio()
    private var ticker: AnyCancellable?
    private var started = false
    /// Last successfully loaded ESP animation image (for Share).
    private(set) var imageData: Data?
    private var soundTrack: PanelAudio.Track = .tick
    /// Set by loadSample before load. Cleared once load consumes it.
    private var pendingTrack: PanelAudio.Track?

    init() {
        frame = [UInt8](repeating: 0, count: MatrixController.waveshare.width * MatrixController.waveshare.height * 3)
    }

    func start() {
        guard !started else { return }
        started = true
        loadBundledDemo()
        ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    func tick() {
        guard running else {
            syncAudio()
            return
        }
        if machine.halted || machine.fault != nil {
            running = false
            syncAudio()
            return
        }
        let budget = (1000.0 / 30.0) * Double(speed)
        machine.advance(ms: budget)
        publish()
        if machine.halted || machine.fault != nil {
            running = false
            if let fault = machine.fault {
                errorText = fault
            }
        }
        syncAudio()
    }

    func toggleRun() {
        if machine.halted || machine.fault != nil { return }
        running.toggle()
        syncAudio()
    }

    func setMuted(_ value: Bool) {
        muted = value
        syncAudio()
    }

    func reset() {
        let code = machine.code
        guard !code.isEmpty else { return }
        machine.load(code)
        errorText = nil
        running = true
        publish()
        syncAudio()
    }

    func load(data: Data, name: String) {
        let track = pendingTrack ?? .tick
        pendingTrack = nil
        do {
            let program = try ESPImage.program(in: data)
            machine.load(program)
            imageData = data
            firmwareName = name
            errorText = nil
            running = true
            soundTrack = track
            publish()
            syncAudio()
        } catch {
            let message = (error as? FirmwareError)?.message ?? error.localizedDescription
            errorText = "\(name): \(message)"
        }
    }



    func applyController(_ next: MatrixController) {
        controller = next
        machine.setPanel(next)
        publish()
    }

    func loadSample(_ sample: SampleAnimation) {
        pendingTrack = sample.id == "nyan-cat" ? .nyan : .tick
        guard let url = Bundle.main.url(forResource: sample.resource, withExtension: "bin", subdirectory: "Samples") else {
            pendingTrack = nil
            errorText = "\(sample.name) is missing from the app bundle."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            load(data: data, name: sample.name)
        } catch {
            pendingTrack = nil
            errorText = "\(sample.name): \(error.localizedDescription)"
        }
    }

    func loadText(text: String, colors: [TextFirmware.RGB], defaultColor: TextFirmware.RGB, effect: TextFirmware.Effect) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "Enter some text to show on the panel."
            return
        }
        guard let image = TextFirmware.convert(
            text: text,
            colors: colors,
            defaultColor: defaultColor,
            effect: effect,
            width: controller.width,
            height: controller.height
        ) else {
            errorText = "Enter some text to show on the panel."
            return
        }
        let name = "text-" + effect.rawValue.lowercased().replacingOccurrences(of: " ", with: "-") + ".bin"
        load(data: image, name: name)
    }

    /// Temporary file for the share sheet. Named as an animation for the MatrixEmu player.
    func exportAnimationURL() throws -> URL {
        guard let data = imageData else {
            throw FirmwareError(message: "Nothing to share yet — load an animation first.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("animation.bin")
        try data.write(to: url, options: .atomic)
        return url
    }

    func loadGIF(data: Data, name: String) {
        do {
            let image = try GIFFirmware.convert(data, width: controller.width, height: controller.height)
            load(data: image, name: name)
        } catch {
            let message = (error as? GIFFirmware.ConvertError)?.message
                ?? (error as? FirmwareError)?.message
                ?? error.localizedDescription
            errorText = "\(name): \(message)"
        }
    }

    func loadBundledDemo() {
        guard let url = Bundle.main.url(forResource: "demo", withExtension: "bin") else {
            errorText = "Embedded demo.bin is missing from the app bundle."
            running = false
            return
        }
        do {
            let data = try Data(contentsOf: url)
            load(data: data, name: "demo.bin")
            if errorText == nil {
                running = true
            }
        } catch {
            errorText = "Embedded demo.bin could not be read."
            running = false
        }
    }

    private func publish() {
        frame = machine.hub.latched
        virtualMs = machine.timeMs
        halted = machine.halted
        scanAddr = machine.hub.addr
        oeBlanked = machine.hub.oeHigh
    }

    /// Play while the animation is running and mute is off.
    private func syncAudio() {
        let on = running && !muted && !machine.halted && machine.fault == nil
        audio.setTrack(soundTrack)
        audio.setPlaying(on)
    }
}
