import AppKit

/// Downloads the speech models on first launch, so a fresh Mac needs nothing but the app.
///   - Whisper large-v3-turbo (q5), ~575 MB, from the official whisper.cpp Hugging Face repo
///   - Silero voice detection, ~1 MB, from the official ggml-org Hugging Face repo
final class ModelInstaller: NSObject, URLSessionDownloadDelegate {
    struct Item {
        let name: String
        let url: URL
        let dest: URL
    }

    static let items: [Item] = [
        Item(name: "speech model",
             url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
             dest: Settings.modelURL),
        Item(name: "voice detection model",
             url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!,
             dest: Settings.vadModelURL),
    ]

    static var missing: [Item] { items.filter { !FileManager.default.fileExists(atPath: $0.dest.path) } }

    var onProgress: ((String) -> Void)?
    var onDone: ((Error?) -> Void)?

    private var queue: [Item] = []
    private var current: Item?
    private var failure: Error?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func start() {
        queue = Self.missing
        next()
    }

    private func next() {
        guard !queue.isEmpty else { onDone?(nil); return }
        let item = queue.removeFirst()
        current = item
        failure = nil
        onProgress?("Downloading \(item.name)…")
        session.downloadTask(with: item.url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let item = current, totalBytesExpectedToWrite > 0 else { return }
        let pct = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
        onProgress?("Downloading \(item.name)… \(pct)%")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let item = current else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            failure = DictateError("Download of the \(item.name) failed (HTTP \(status)).")
            return
        }
        do {
            try FileManager.default.createDirectory(at: item.dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: item.dest)
            try FileManager.default.moveItem(at: location, to: item.dest)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let err = error ?? failure {
            onDone?(err)
        } else {
            next()
        }
    }
}

extension Keychain {
    /// Saves the key with /usr/bin/security (the same tool that reads it), so no Keychain prompts appear later.
    static func saveAnthropicKey(_ key: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["add-generic-password", "-U", "-a", NSUserName(), "-s", "anthropic-api-key", "-w", key]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        resetCache()
        return p.terminationStatus == 0
    }

    /// Checks a key with a free call that lists models.
    static func validate(_ key: String, completion: @escaping (Bool, String) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                if code == 200 { completion(true, "API key saved and working.") }
                else if code == 401 { completion(false, "That API key was rejected. Check it and try again.") }
                else { completion(false, "Couldn't check the key (\(err?.localizedDescription ?? "HTTP \(code)")). It was saved anyway.") }
            }
        }.resume()
    }
}
