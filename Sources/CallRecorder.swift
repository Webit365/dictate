import AVFoundation
import ScreenCaptureKit

/// Records a call as two separate tracks written straight to disk:
///   me.caf   – your microphone
///   them.caf – everything your Mac plays (Zoom, Slack huddle, Teams, Meet…)
/// Keeping them apart is what lets the notes say who said what.
final class CallRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let micEngine = AVAudioEngine()
    private var stream: SCStream?
    private let micWriter = TrackWriter()
    private let sysWriter = TrackWriter()
    private let sysQueue = DispatchQueue(label: "dictate.call.system-audio")

    private(set) var folder: URL?
    private(set) var startedAt: Date?
    var isRecording: Bool { startedAt != nil }

    func start(completion: @escaping (Error?) -> Void) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm ss"
        let dir = Settings.callsDir.appendingPathComponent(stamp.string(from: Date()))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            try micWriter.open(dir.appendingPathComponent("me.caf"), origin: origin)
            try sysWriter.open(dir.appendingPathComponent("them.caf"), origin: origin)

            let input = micEngine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0 else { throw DictateError("No microphone input is available.") }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, when in
                self?.micWriter.write(buf, at: when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil)
            }
            micEngine.prepare()
            try micEngine.start()
        } catch {
            cleanupAfterFailure()
            completion(error)
            return
        }
        folder = dir

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard let display = content?.displays.first else {
                DispatchQueue.main.async {
                    self.cleanupAfterFailure()
                    completion(DictateError("Wisp needs Screen & System Audio Recording permission to hear the other side of the call. "
                                            + "Turn it on in System Settings → Privacy & Security, then try again."
                                            + (error.map { " (\($0.localizedDescription))" } ?? "")))
                }
                return
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            // Only audio is wanted; keep the (required) video side as tiny and slow as possible.
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.showsCursor = false

            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            do {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sysQueue)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sysQueue)
            } catch {
                DispatchQueue.main.async { self.cleanupAfterFailure(); completion(error) }
                return
            }
            s.startCapture { err in
                DispatchQueue.main.async {
                    if let err {
                        self.cleanupAfterFailure()
                        completion(err)
                    } else {
                        self.stream = s
                        self.startedAt = Date()
                        completion(nil)
                    }
                }
            }
        }
    }

    /// Stops recording and returns the call folder (with me.caf and them.caf) and its length.
    func stop(completion: @escaping (URL?, TimeInterval) -> Void) {
        let dir = folder
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        let finish = { [self] in
            sysQueue.async { [self] in
                micWriter.close()
                sysWriter.close()
                DispatchQueue.main.async {
                    self.stream = nil
                    self.startedAt = nil
                    self.folder = nil
                    completion(dir, duration)
                }
            }
        }
        if let stream { stream.stopCapture { _ in finish() } } else { finish() }
    }

    private func cleanupAfterFailure() {
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        micWriter.close()
        sysWriter.close()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        startedAt = nil
        stream = nil
    }

    // MARK: ScreenCaptureKit

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let buf = sb.pcmBuffer() else { return }
        sysWriter.write(buf, at: CMSampleBufferGetPresentationTimeStamp(sb).seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Dictate: system audio stream stopped: \(error.localizedDescription)")
    }
}

/// Converts incoming audio to 16 kHz mono and appends it to a file.
/// Gaps (macOS sends no system audio while nothing is playing) are filled with
/// silence using each buffer's host-clock timestamp, so both tracks share one timeline.
final class TrackWriter {
    private var file: AVAudioFile?
    private var origin: Double = 0
    private var writtenFrames: Int64 = 0
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let lock = NSLock()
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    func open(_ url: URL, origin: Double) throws {
        lock.lock(); defer { lock.unlock() }
        self.origin = origin
        writtenFrames = 0
        file = try AVAudioFile(forWriting: url, settings: Self.format.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ buffer: AVAudioPCMBuffer, at hostSeconds: Double?) {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        if let t = hostSeconds, t.isFinite {
            let offset = t - origin
            if offset >= 0, offset < 86_400 {
                var gap = Int64(offset * 16000) - writtenFrames
                if gap > 1600 {   // more than 0.1 s missing: pad with silence
                    while gap > 0 {
                        let n = AVAudioFrameCount(min(gap, 160_000))
                        guard let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: n) else { break }
                        silence.frameLength = n   // new buffers are zero-filled
                        if let ch = silence.floatChannelData { ch[0].initialize(repeating: 0, count: Int(n)) }
                        try? file.write(from: silence)
                        writtenFrames += Int64(n)
                        gap -= Int64(n)
                    }
                }
            }
        }
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
            converterInput = buffer.format
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var fed = false
        let status = converter.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true
            st.pointee = .haveData
            return buffer
        }
        if status != .error, out.frameLength > 0 {
            try? file.write(from: out)
            writtenFrames += Int64(out.frameLength)
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        file = nil          // AVAudioFile finalizes the file when released
        converter = nil
        converterInput = nil
    }
}

private extension CMSampleBuffer {
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let desc = formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames),
                                                                  into: buf.mutableAudioBufferList)
        return status == noErr ? buf : nil
    }
}
