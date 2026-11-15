import Foundation
import whisper

/// Runs Whisper on this Mac. The model loads on first use and is freed
/// after 5 idle minutes so it doesn't hold memory while you work.
final class Transcriber {
    static let idleUnloadSeconds: TimeInterval = 300

    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "dictate.whisper", qos: .userInitiated)
    private var unloadWork: DispatchWorkItem?

    /// Frees the model. Must run before the process exits, or ggml's Metal cleanup aborts.
    func shutdown() {
        queue.sync {
            unloadWork?.cancel()
            if let c = ctx { whisper_free(c); ctx = nil }
        }
    }

    /// Start loading while the user is still talking, so transcription starts sooner.
    func preload() {
        queue.async { [self] in
            unloadWork?.cancel()
            _ = loadIfNeeded()
        }
    }

    private func loadIfNeeded() -> Bool {
        if ctx != nil { return true }
        var cp = whisper_context_default_params()
        cp.use_gpu = true
        cp.flash_attn = true
        ctx = whisper_init_from_file_with_params(Settings.modelURL.path, cp)
        return ctx != nil
    }

    func transcribe(_ samples: [Float], vocabulary: [String],
                    completion: @escaping (Result<String, Error>) -> Void) {
        queue.async { [self] in
            unloadWork?.cancel()
            defer { scheduleUnload() }
            guard loadIfNeeded(), let ctx else {
                completion(.failure(DictateError("Couldn't load the Whisper model at \(Settings.modelURL.path)")))
                return
            }
            var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            p.n_threads = Int32(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            p.no_timestamps = true
            p.no_context = true
            p.single_segment = false
            p.print_progress = false
            p.print_realtime = false
            p.print_special = false
            p.print_timestamps = false
            p.suppress_blank = true
            p.suppress_nst = true

            // Whisper spells names better when they appear in its starting prompt.
            let prompt = vocabulary.isEmpty ? "" : vocabulary.joined(separator: ", ") + "."
            let rc: Int32 = "en".withCString { lang in
                prompt.withCString { pr in
                    p.language = lang
                    p.initial_prompt = prompt.isEmpty ? nil : pr
                    return samples.withUnsafeBufferPointer { buf in
                        whisper_full(ctx, p, buf.baseAddress, Int32(buf.count))
                    }
                }
            }
            guard rc == 0 else {
                completion(.failure(DictateError("Whisper failed (code \(rc))")))
                return
            }
            var text = ""
            for i in 0..<whisper_full_n_segments(ctx) {
                if let c = whisper_full_get_segment_text(ctx, i) { text += String(cString: c) }
            }
            completion(.success(Transcriber.tidy(text)))
        }
    }

    struct Segment { let start: Double; let end: Double; let text: String }

    /// Long-form transcription with timestamps, for call recordings.
    /// Voice detection (the small Silero model) finds each stretch of speech first; each stretch is
    /// transcribed on its own with its real start time. That skips silence (faster, and Whisper can't
    /// invent words in quiet parts) while keeping an accurate timeline for "who said what, when".
    func transcribeSegments(_ samples: [Float], vocabulary: [String], progress: @escaping (Int) -> Void,
                            completion: @escaping (Result<[Segment], Error>) -> Void) {
        queue.async { [self] in
            unloadWork?.cancel()
            defer { scheduleUnload() }
            guard loadIfNeeded(), let ctx else {
                completion(.failure(DictateError("Couldn't load the Whisper model.")))
                return
            }
            let rate = 16000.0
            let chunks = speechChunks(samples) ?? [(0, samples.count)]
            let total = max(1, chunks.reduce(0) { $0 + $1.1 - $1.0 })
            var done = 0
            var segments: [Segment] = []
            for (start, end) in chunks {
                let slice = Array(samples[start..<end])
                let offset = Double(start) / rate
                guard let segs = runWhisper(ctx, slice, vocabulary: vocabulary, timestamps: true) else {
                    completion(.failure(DictateError("Whisper failed while transcribing the call.")))
                    return
                }
                segments += segs.map { Segment(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
                done += end - start
                progress(Int(Double(done) / Double(total) * 100))
            }
            completion(.success(segments))
        }
    }

    /// Returns sample ranges that contain speech, grouped into chunks of up to ~30 s,
    /// or nil if the voice-detection model isn't available.
    private func speechChunks(_ samples: [Float]) -> [(Int, Int)]? {
        guard FileManager.default.fileExists(atPath: Settings.vadModelURL.path) else { return nil }
        var cp = whisper_vad_default_context_params()
        cp.n_threads = 4
        cp.use_gpu = false
        guard let vctx = whisper_vad_init_from_file_with_params(Settings.vadModelURL.path, cp) else { return nil }
        defer { whisper_vad_free(vctx) }
        let vp = whisper_vad_default_params()
        guard let segs = samples.withUnsafeBufferPointer({ buf in
            whisper_vad_segments_from_samples(vctx, vp, buf.baseAddress, Int32(buf.count))
        }) else { return nil }
        defer { whisper_vad_free_segments(segs) }

        // VAD times are in centiseconds.
        var ranges: [(Double, Double)] = []
        for i in 0..<whisper_vad_segments_n_segments(segs) {
            ranges.append((Double(whisper_vad_segments_get_segment_t0(segs, i)) / 100,
                           Double(whisper_vad_segments_get_segment_t1(segs, i)) / 100))
        }
        // Join speech separated by short pauses, up to ~30 s per chunk; pad the edges a little.
        var merged: [(Double, Double)] = []
        for r in ranges {
            if let last = merged.last, r.0 - last.1 < 1.0, r.1 - last.0 < 30 {
                merged[merged.count - 1].1 = r.1
            } else {
                merged.append(r)
            }
        }
        let n = samples.count
        return merged.compactMap { r in
            let a = max(0, Int((r.0 - 0.25) * 16000))
            let b = min(n, Int((r.1 + 0.25) * 16000))
            return b - a > 1600 ? (a, b) : nil
        }
    }

    private func runWhisper(_ ctx: OpaquePointer, _ samples: [Float], vocabulary: [String],
                            timestamps: Bool) -> [Segment]? {
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = Int32(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        p.no_timestamps = !timestamps
        p.no_context = true
        p.print_progress = false
        p.print_realtime = false
        p.print_special = false
        p.print_timestamps = false
        p.suppress_blank = true
        p.suppress_nst = true
        let prompt = vocabulary.isEmpty ? "" : vocabulary.joined(separator: ", ") + "."
        let rc: Int32 = "en".withCString { lang in
            prompt.withCString { pr in
                p.language = lang
                p.initial_prompt = prompt.isEmpty ? nil : pr
                return samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, p, buf.baseAddress, Int32(buf.count))
                }
            }
        }
        guard rc == 0 else { return nil }
        var out: [Segment] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            guard let c = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = Transcriber.tidy(String(cString: c))
            if text.isEmpty { continue }
            // whisper.cpp segment timestamps are in 10 ms units
            out.append(Segment(start: Double(whisper_full_get_segment_t0(ctx, i)) / 100,
                               end: Double(whisper_full_get_segment_t1(ctx, i)) / 100, text: text))
        }
        return out
    }

    private func scheduleUnload() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let c = self.ctx else { return }
            whisper_free(c)
            self.ctx = nil
        }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + Self.idleUnloadSeconds, execute: work)
    }

    /// Removes Whisper's non-speech markers like [BLANK_AUDIO] or (music).
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\((?i:music|silence|applause|laughter|inaudible|blank_audio)\)"#,
                                   with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
