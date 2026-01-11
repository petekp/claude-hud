import AVFoundation
import Foundation

final class ReadyChime {
    static let shared = ReadyChime()

    private var audioEngine: AVAudioEngine?
    private var mixer: AVAudioMixerNode?
    private var isPlaying = false

    private init() {
        setupAudioEngine()
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        mixer = AVAudioMixerNode()

        guard let engine = audioEngine, let mixer = mixer else { return }

        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)

        do {
            try engine.start()
        } catch {
            print("ReadyChime: Failed to start audio engine: \(error)")
        }
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.playDualTone()
        }
    }

    private func playDualTone() {
        guard let engine = audioEngine, let mixer = mixer else {
            isPlaying = false
            return
        }

        let sampleRate: Double = 44100
        let duration1: Double = 0.12
        let duration2: Double = 0.18
        let gap: Double = 0.06

        let freq1: Double = 880   // A5
        let freq2: Double = 1318  // E6 (perfect fifth up, pleasing interval)

        let totalDuration = duration1 + gap + duration2
        let frameCount = AVAudioFrameCount(totalDuration * sampleRate)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            isPlaying = false
            return
        }

        buffer.frameLength = frameCount

        guard let floatData = buffer.floatChannelData?[0] else {
            isPlaying = false
            return
        }

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            var sample: Float = 0

            if t < duration1 {
                let envelope = smoothEnvelope(t: t, duration: duration1, attackTime: 0.01, releaseTime: 0.04)
                let wave = sin(2.0 * .pi * freq1 * t)
                let harmonic = sin(4.0 * .pi * freq1 * t) * 0.15
                sample = Float((wave + harmonic) * envelope * 0.25)
            } else if t >= duration1 + gap && t < totalDuration {
                let t2 = t - duration1 - gap
                let envelope = smoothEnvelope(t: t2, duration: duration2, attackTime: 0.01, releaseTime: 0.08)
                let wave = sin(2.0 * .pi * freq2 * t2)
                let harmonic = sin(4.0 * .pi * freq2 * t2) * 0.12
                sample = Float((wave + harmonic) * envelope * 0.28)
            }

            floatData[i] = sample
        }

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: mixer, format: format)

        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        playerNode.play()

        Thread.sleep(forTimeInterval: totalDuration + 0.05)

        playerNode.stop()
        engine.detach(playerNode)
        isPlaying = false
    }

    private func smoothEnvelope(t: Double, duration: Double, attackTime: Double, releaseTime: Double) -> Double {
        let sustainEnd = duration - releaseTime

        if t < attackTime {
            let x = t / attackTime
            return x * x * (3 - 2 * x)
        } else if t < sustainEnd {
            return 1.0
        } else {
            let x = (t - sustainEnd) / releaseTime
            let decay = 1 - x * x * (3 - 2 * x)
            return max(0, decay)
        }
    }
}
