import AppKit

// Headless test: Dictate --test some.wav  (transcribes + cleans a file, prints result, no paste)
if let i = CommandLine.arguments.firstIndex(of: "--test"), i + 1 < CommandLine.arguments.count {
    TestRunner.run(path: CommandLine.arguments[i + 1])
}

if let i = CommandLine.arguments.firstIndex(of: "--test-call"), i + 1 < CommandLine.arguments.count {
    CallTestRunner.run(folder: CommandLine.arguments[i + 1])
}

if let i = CommandLine.arguments.firstIndex(of: "--segments"), i + 1 < CommandLine.arguments.count {
    let samples = (try? AudioFile.load16kMono(URL(fileURLWithPath: CommandLine.arguments[i + 1]))) ?? []
    let sem = DispatchSemaphore(value: 0)
    let t = Transcriber()
    t.transcribeSegments(samples, vocabulary: [], progress: { _ in }) { r in
        for seg in (try? r.get()) ?? [] { print(String(format: "%6.2f-%6.2f  %@", seg.start, seg.end, seg.text)) }
        sem.signal()
    }
    sem.wait(); t.shutdown(); exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
