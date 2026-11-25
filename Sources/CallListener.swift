import AVFoundation
import ScreenCaptureKit
import whisper

/// What the call watcher needs from a listener (a fake one is used in tests).
protocol VoiceListener: AnyObject {
    /// Seconds of voice heard so far.
    var voiceSeconds: Double { get }
    /// When a voice was last heard, or nil if never.
    var lastVoice: Date? { get }
    /// True if listening couldn't start (app not found, no permission…).
    var failed: Bool { get }
    func stop()
}

/// Listens only to one call app's own sound (not the mic, not other apps) and counts how much of it
/// is a voice. Hearing the other people means you've joined the call; a ringing or declined call
/// (which can still hold the microphone, as Slack huddles do) plays no voices.
final class CallListener: NSObject, VoiceListener, SCStreamOutput, SCStreamDelegate {
    private let bundlePrefix: String
    private let queue = DispatchQueue(label: "wisp.call-listener")
    private let lock = NSLock()
    private var stream: SCStream?
    private var stopped = false
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var pending: [Float] = []
    private var vad: OpaquePointer?
    private var _voiceSeconds = 0.0
    private var _lastVoice: Date?
    private var _failed = false

    var voiceSeconds: Double { lock.lock(); defer { lock.unlock() }; return _voiceSeconds }
    var lastVoice: Date? { lock.lock(); defer { lock.unlock() }; return _lastVoice }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return _failed }

    init(bundlePrefix: String) {
        self.bundlePrefix = bundlePrefix
        super.init()
        start()
    }

    private func fail(_ why: String) {
        NSLog("Wisp: can't listen to \(bundlePrefix) (\(why)); auto-start falls back to the microphone check.")
        lock.lock(); _failed = true; lock.unlock()
    }

    private func start() {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            guard let content, let display = content.displays.first else { return self.fail(error?.localizedDescription ?? "no display") }
            let apps = content.applications.filter { $0.bundleIdentifier.hasPrefix(self.bundlePrefix) }
            guard !apps.isEmpty else { return self.fail("app not found") }

            let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 1
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.showsCursor = false

            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            do {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch { return self.fail(error.localizedDescription) }
            s.startCapture { err in
                if let err { return self.fail(err.localizedDescription) }
                self.lock.lock()
                let tooLate = self.stopped
                if !tooLate { self.stream = s }
                self.lock.unlock()
                if tooLate { s.stopCapture { _ in } }
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let s = stream
        stream = nil
        lock.unlock()
        s?.stopCapture { _ in }
        queue.async { [self] in
            if let vad { whisper_vad_free(vad) }
            vad = nil
            pending = []
        }
    }

    // MARK: Audio in

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let buf = sb.pcmBuffer16k(&converter, &converterInput) else { return }
        guard let ch = buf.floatChannelData else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
        // Judge the audio two seconds at a time.
        while pending.count >= 32000 {
            let chunk = Array(pending.prefix(32000))
            pending.removeFirst(32000)
            let secs = voiceIn(chunk)
            if secs > 0 {
                lock.lock(); _voiceSeconds += secs; _lastVoice = Date(); lock.unlock()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Wisp: call listener stopped: \(error.localizedDescription)")
    }

    /// Seconds of speech in a 16 kHz chunk: the voice-detection model when it's installed, else loudness.
    private func voiceIn(_ samples: [Float]) -> Double {
        if vad == nil, !stopped, FileManager.default.fileExists(atPath: Settings.vadModelURL.path) {
            var cp = whisper_vad_default_context_params()
            cp.n_threads = 2
            cp.use_gpu = false
            vad = whisper_vad_init_from_file_with_params(Settings.vadModelURL.path, cp)
        }
        if let vad {
            let vp = whisper_vad_default_params()
            guard let segs = samples.withUnsafeBufferPointer({ whisper_vad_segments_from_samples(vad, vp, $0.baseAddress, Int32($0.count)) })
            else { return 0 }
            defer { whisper_vad_free_segments(segs) }
            var total = 0.0
            for i in 0..<whisper_vad_segments_n_segments(segs) {   // times are in centiseconds
                total += Double(whisper_vad_segments_get_segment_t1(segs, i) - whisper_vad_segments_get_segment_t0(segs, i)) / 100
            }
            return total
        }
        // No model: count 50 ms frames that are clearly audible.
        var loud = 0
        stride(from: 0, to: samples.count - 800, by: 800).forEach { i in
            var sum: Float = 0
            for j in i..<(i + 800) { sum += samples[j] * samples[j] }
            if (sum / 800).squareRoot() > 0.02 { loud += 1 }
        }
        return Double(loud) * 0.05
    }
}

private extension CMSampleBuffer {
    /// The sample buffer as 16 kHz mono float audio.
    func pcmBuffer16k(_ converter: inout AVAudioConverter?, _ converterInput: inout AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let desc = formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames),
                                                           into: buf.mutableAudioBufferList) == noErr else { return nil }
        if converter == nil || converterInput != format {
            converter = AVAudioConverter(from: format, to: TrackWriter.format)
            converterInput = format
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(frames) * 16000 / format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: TrackWriter.format, frameCapacity: capacity) else { return nil }
        var fed = false
        let status = converter.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true
            st.pointee = .haveData
            return buf
        }
        return status != .error && out.frameLength > 0 ? out : nil
    }
}
