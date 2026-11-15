import AVFoundation

private let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                          channels: 1, interleaved: false)!

/// Records the microphone only while dictation is active, as 16 kHz mono floats for Whisper.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    /// Loudness (RMS) of each chunk while recording, for the floating head's mouth. Called off the main thread.
    var onLevel: ((Float) -> Void)?

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw DictateError("No microphone input is available.")
        }
        converter = AVAudioConverter(from: inFormat, to: whisperFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = whisperFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: capacity) else { return }
        var fed = false
        let status = converter.convert(to: out, error: nil) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = out.floatChannelData else { return }
        let chunk = UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
        if let onLevel, !chunk.isEmpty {
            var sum: Float = 0
            for v in chunk { sum += v * v }
            onLevel((sum / Float(chunk.count)).squareRoot())
        }
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

enum AudioFile {
    /// Loads any audio file and converts it to 16 kHz mono floats (used by --test).
    static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: inFormat, to: whisperFormat) else {
            throw DictateError("Could not read \(url.lastPathComponent)")
        }
        try file.read(into: inBuf)
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * 16000 / inFormat.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: capacity) else {
            throw DictateError("Out of memory converting audio")
        }
        var fed = false
        _ = converter.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true
            st.pointee = .haveData
            return inBuf
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
