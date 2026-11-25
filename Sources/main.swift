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
        print("mic: \(users.isEmpty ? "-" : users.joined(separator: ", "))  →  call: \(CallWatcher.currentCall().map { $0.name + ($0.listenTo == nil ? "" : " (waits for voices)") } ?? "none")")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 2)
    }
    exit(0)
}

// Wisp --listen com.apple.QuickTimePlayerX 20  (prints how many seconds of voice that app plays)
if let i = CommandLine.arguments.firstIndex(of: "--listen"), i + 1 < CommandLine.arguments.count {
    let secs = i + 2 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 2]) ?? 20 : 20
    let l = CallListener(bundlePrefix: CommandLine.arguments[i + 1])
    for _ in 0..<max(1, secs / 2) {
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        print(l.failed ? "failed" : String(format: "voice: %.1f s", l.voiceSeconds)); fflush(stdout)
    }
    l.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    exit(0)
}

// Wisp --test-call-watcher  (checks the start/end timing with fake calls)
if CommandLine.arguments.contains("--test-call-watcher") {
    final class FakeListener: VoiceListener {
        var voiceSeconds = 0.0
        var lastVoice: Date?
        var failed = false
        var stopped = false
        func stop() { stopped = true }
    }
    var ok = true
    func check(_ name: String, _ log: [String], _ expected: [String]) {
        print((log == expected ? "PASS " : "FAIL ") + name + ": \(log)" + (log == expected ? "" : ", expected \(expected)"))
        ok = ok && log == expected
    }

    // 1. Mic-only app (FaceTime): timing of start and end.
    do {
        let w = CallWatcher()
        var mic: DetectedCall?
        var log: [String] = []
        w.source = { mic }
        w.onCallStarted = { log.append("start \($0)") }
        w.onCallEnded = { log.append("end") }
        let t0 = Date()
        func at(_ s: Double) { w.tick(now: t0.addingTimeInterval(s)) }
        let ft = DetectedCall(name: "FaceTime", listenTo: nil)
        mic = ft; at(0); at(2)                   // only 2 s: too short
        mic = nil; at(3)                         // blip ends, nothing happened
        mic = ft; at(10); at(12); at(14)         // 4 s on the mic: call starts
        mic = nil; at(16); at(24)                // 10 s quiet (muted?): still in the call
        mic = ft; at(26)                         // back on the mic
        mic = nil; at(30); at(40); at(42)        // 16 s quiet: call ends
        check("mic-only timing", log, ["start FaceTime", "end"])
    }

    // 2. Slack huddle rings and is declined: Slack holds the mic but plays no voices. No notes.
    // 3. Then a huddle you join: voices arrive, notes start; you leave, Slack keeps the mic, notes stop.
    do {
        let w = CallWatcher()
        var mic: DetectedCall?
        var log: [String] = []
        var fake = FakeListener()
        var made = 0
        w.source = { mic }
        w.makeListener = { _ in made += 1; fake = FakeListener(); return fake }
        w.onCallStarted = { log.append("start \($0)") }
        w.onCallEnded = { log.append("end") }
        let t0 = Date()
        func at(_ s: Double) { w.tick(now: t0.addingTimeInterval(s)) }
        let slack = DetectedCall(name: "Slack", listenTo: "com.tinyspeck.slackmacgap")
        mic = slack
        for s in stride(from: 0.0, through: 2400, by: 2) { at(s) }   // 40 min holding the mic, silent
        check("declined huddle", log, [])
        mic = nil; at(2402); at(2420)
        check("declined huddle ends", log, [])
        let listenersBefore = made
        print((fake.stopped ? "PASS" : "FAIL") + " listener stopped when Slack let go of the mic")
        ok = ok && fake.stopped

        mic = slack; at(3000); at(3002); at(3004); at(3006)        // joining: mic open, nobody talking yet
        check("joined, silence so far", log, [])
        fake.voiceSeconds = 1; fake.lastVoice = t0.addingTimeInterval(3007); at(3008)
        check("one second of voice", log, [])
        fake.voiceSeconds = 3; fake.lastVoice = t0.addingTimeInterval(3009); at(3010)
        check("joined huddle", log, ["start Slack"])
        print((made == listenersBefore + 1 ? "PASS" : "FAIL") + " one listener for the joined huddle"); ok = ok && made == listenersBefore + 1
        fake.lastVoice = t0.addingTimeInterval(3200); at(3300); at(3400)   // still talking
        check("mid-call", log, ["start Slack"])
        at(3200 + 299)
        check("4:59 of silence", log, ["start Slack"])
        at(3200 + 300)                                              // you left; Slack kept the mic
        check("left the huddle", log, ["start Slack", "end"])
        at(3502); at(3504); at(3506); at(3508)                      // still holding the mic, silent: stays off
        check("after leaving", log, ["start Slack", "end"])
    }

    // 4. Listening fails (no permission / app not found): fall back to the mic alone.
    do {
        let w = CallWatcher()
        var log: [String] = []
        w.source = { DetectedCall(name: "Slack", listenTo: "com.tinyspeck.slackmacgap") }
        w.makeListener = { _ in let f = FakeListener(); f.failed = true; return f }
        w.onCallStarted = { log.append("start \($0)") }
        let t0 = Date()
        w.tick(now: t0); w.tick(now: t0.addingTimeInterval(4))
        check("listener failed falls back", log, ["start Slack"])
    }
    exit(ok ? 0 : 1)
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
