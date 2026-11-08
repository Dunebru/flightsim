import AVFoundation
import Synchronization

/// Plays the synthesized aircraft sound through AVAudioEngine. The flight sets the parameters on
/// the main thread; the audio thread renders from them.
final class FlightAudio {
    /// The synthesizer, shared with the audio thread.
    nonisolated final class Box: Sendable {
        let synth: Mutex<EngineSynth>
        init(_ s: EngineSynth) { synth = Mutex(s) }
    }

    private let engine = AVAudioEngine()
    private let box: Box
    private var source: AVAudioSourceNode?
    private var started = false

    init() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        box = Box(EngineSynth(sampleRate: rate > 0 ? rate : 48_000))
    }

    func start() {
        guard !started else { return }
        #if os(iOS)
        // Ambient: mixes with other audio and follows the silent switch, as games do.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 1) else { return }
        let layers = Self.loadTurbineLayers()
        box.synth.withLock { $0.turbineLayers = layers }
        let node = Self.sourceNode(format: format, box: box)
        engine.attach(node)
        engine.mainMixerNode.outputVolume = 0.8
        do {
            try engine.connectNode(node, to: engine.mainMixerNode, format: format)
            try engine.start()
            source = node
            started = true
        } catch {
            engine.detach(node)
        }
    }

    /// Built outside the main actor: the render block runs on the audio thread.
    nonisolated private static func sourceNode(format: AVAudioFormat, box: Box) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frames, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let data = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            box.synth.withLock { $0.render(into: data, frames: Int(frames)) }
            return noErr
        }
    }

    /// The CFM56 recordings in the app bundle (Bundle/Sounds/CFM56), as seamless loops.
    nonisolated static func loadTurbineLayers(directory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Bundle/Sounds/CFM56"))
        -> [SampleLoop] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "caf" }.sorted { $0.path < $1.path }.compactMap { url in
            guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData?[0] else { return nil }
            var loop = SampleLoop(samples: Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))),
                                  sampleRate: file.processingFormat.sampleRate)
            loop.name = url.deletingPathExtension().lastPathComponent
            return loop
        }
    }

    func stop() {
        guard started else { return }
        engine.stop()
        started = false
    }

    func update(_ p: SoundParameters) {
        box.synth.withLock { $0.target = p }
    }

    func touchdown(_ strength: Double) {
        box.synth.withLock { $0.touchdown(strength) }
    }
}
