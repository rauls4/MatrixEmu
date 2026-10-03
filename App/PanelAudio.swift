import AVFoundation
import Foundation

/// Short generated loops for the panel.
/// Nyan Cat uses an original pulse-wave phrase written for this app.
/// It is not the Nyan Cat recording and not that melody.
/// Other animations share a soft tick.
final class PanelAudio {
    enum Track: Equatable {
        case nyan
        case tick
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var buffers: [Track: AVAudioPCMBuffer] = [:]
    private var track: Track = .tick
    private var playing = false
    private var sessionReady = false

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.85
        if let nyan = Self.makeBuffer(format: format, samples: Self.nyanSamples(rate: format.sampleRate)) {
            buffers[.nyan] = nyan
        }
        if let tick = Self.makeBuffer(format: format, samples: Self.tickSamples(rate: format.sampleRate)) {
            buffers[.tick] = tick
        }
    }

    func setTrack(_ next: Track) {
        guard next != track else { return }
        track = next
        if playing {
            begin()
        }
    }

    /// Start or stop the loop. Idempotent.
    func setPlaying(_ on: Bool) {
        guard on != playing else { return }
        playing = on
        if on {
            begin()
        } else {
            player.stop()
            engine.pause()
        }
    }

    private func begin() {
        prepareSession()
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            playing = false
            return
        }
        player.stop()
        guard let buffer = buffers[track] else {
            playing = false
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: [.loops])
        player.play()
    }

    private func prepareSession() {
        #if os(iOS)
        if sessionReady { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            sessionReady = true
        } catch {
            sessionReady = false
        }
        #endif
    }

    private static func makeBuffer(format: AVAudioFormat, samples: [Float]) -> AVAudioPCMBuffer? {
        let count = AVAudioFrameCount(samples.count)
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let dst = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = count
        for i in 0..<samples.count {
            dst[i] = samples[i]
        }
        return buffer
    }

    /// Eight-note loop, about 1.2 s. Lead is a 25% pulse; bass is a square.
    private static func nyanSamples(rate: Double) -> [Float] {
        let lead: [Double] = [659.25, 783.99, 880.00, 783.99, 659.25, 587.33, 659.25, 523.25]
        let bass: [Double] = [130.81, 130.81, 196.00, 196.00, 220.00, 174.61, 196.00, 130.81]
        let note = 0.15
        let n = Int(rate * note * Double(lead.count))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            let idx = min(Int(t / note), lead.count - 1)
            let local = t - Double(idx) * note
            let env = Float(exp(-local * 6.5))
            let leadS = pulse(t, freq: lead[idx], duty: 0.25)
            let bassS = pulse(t, freq: bass[idx], duty: 0.5)
            out[i] = (leadS * 0.20 + bassS * 0.09) * env
        }
        let fade = min(64, n / 10)
        if fade > 1 {
            for i in 0..<fade {
                let g = Float(i) / Float(fade)
                out[i] *= g
                out[n - 1 - i] *= g
            }
        }
        return out
    }

    /// Quiet blip, then silence, looped.
    private static func tickSamples(rate: Double) -> [Float] {
        let n = Int(rate * 0.42)
        var out = [Float](repeating: 0, count: n)
        let click = min(n, Int(rate * 0.016))
        for i in 0..<click {
            let t = Double(i) / rate
            let env = Float(exp(-t * 110.0))
            let s = sin(2 * Double.pi * 880 * t)
            out[i] = Float(s) * env * 0.16
        }
        return out
    }

    private static func pulse(_ t: Double, freq: Double, duty: Double) -> Float {
        let phase = (t * freq).truncatingRemainder(dividingBy: 1.0)
        return phase < duty ? 1 : -1
    }
}
