import AppKit
import SwiftUI

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

// Wisp --call-watch [seconds]  (prints which apps use the mic and whether that counts as a call)
if let i = CommandLine.arguments.firstIndex(of: "--call-watch") {
    let secs = i + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 1]) ?? 10 : 10
    for _ in 0..<max(1, secs / 2) {
        let users = CallWatcher.micUsers().map { "\($0.bundleID.isEmpty ? "pid \($0.pid)" : $0.bundleID)" }
        print("mic: \(users.isEmpty ? "-" : users.joined(separator: ", "))  →  call: \(CallWatcher.currentCall() ?? "none")")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 2)
    }
    exit(0)
}

// Wisp --test-call-watcher  (checks the start/end timing with a fake call)
if CommandLine.arguments.contains("--test-call-watcher") {
    let w = CallWatcher()
    var micApp: String?
    var log: [String] = []
    w.source = { micApp }
    w.onCallStarted = { log.append("start \($0)") }
    w.onCallEnded = { log.append("end") }
    let t0 = Date()
    func at(_ s: Double) { w.tick(now: t0.addingTimeInterval(s)) }
    micApp = "Zoom"; at(0); at(2)                 // only 2 s: too short
    micApp = nil; at(3)                           // blip ends, nothing happened
    micApp = "Zoom"; at(10); at(12); at(14)       // 4 s on the mic: call starts
    micApp = nil; at(16); at(24)                  // 10 s quiet (muted?): still in the call
    micApp = "Zoom"; at(26)                       // back on the mic
    micApp = nil; at(30); at(40); at(42)          // 16 s quiet: call ends
    let expected = ["start Zoom", "end"]
    print(log == expected ? "PASS \(log)" : "FAIL got \(log), expected \(expected)")
    exit(log == expected ? 0 : 1)
}

// Dictate --render-notes notes.md out.html  (writes the formatted notes page, for previewing the design)
if let i = CommandLine.arguments.firstIndex(of: "--render-notes"), i + 2 < CommandLine.arguments.count {
    let md = (try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8)) ?? ""
    let html = NotesRenderer.html(fromMarkdown: md, title: CallNotes.extractTitle(md) ?? "Call Notes")
    try? html.write(toFile: CommandLine.arguments[i + 2], atomically: true, encoding: .utf8)
    exit(0)
}

// Wisp --test-style "raw transcript"  (cleans the text in every style, prints each; no paste)
if let i = CommandLine.arguments.firstIndex(of: "--test-style"), i + 1 < CommandLine.arguments.count {
    let raw = CommandLine.arguments[i + 1]
    let cases: [(StyleCategory, WritingStyle)] = [(.personal, .formal), (.personal, .casual), (.personal, .veryCasual),
                                                 (.work, .casual), (.email, .formal), (.email, .casual)]
    for (c, st) in cases {
        let sem = DispatchSemaphore(value: 0)
        ClaudeAPI.send(model: Settings.shared.claudeModel.rawValue,
                       system: Cleaner.systemPrompt(vocabulary: Settings.vocabulary(), targetApp: nil, style: st, category: c),
                       user: "<transcript>\n\(raw)\n</transcript>", maxTokens: 2000, effort: "low", timeout: 30) { r in
            switch r {
            case .success(let t): print("[\(c.rawValue) / \(st.rawValue)]\n\(st.enforce(t))\n")
            case .failure(let e): print("[\(c.rawValue) / \(st.rawValue)] error: \(e.localizedDescription)\n")
            }
            sem.signal()
        }
        sem.wait()
    }
    exit(0)
}

// Wisp --render-styles out.png [dark] [notes]  (saves a picture of the Style window, or its Notes tab)
if let i = CommandLine.arguments.firstIndex(of: "--render-styles"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let dark = CommandLine.arguments.contains("dark")
    if CommandLine.arguments.contains("notes") {
        WispWindowState.shared.showNotes = true
        NotesLibrary.shared.reload()
    }
    let view = NSHostingView(rootView: StylesView().environment(\.colorScheme, dark ? .dark : .light))
    view.frame = NSRect(x: 0, y: 0, width: 900, height: 660)
    view.layoutSubtreeIfNeeded()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
