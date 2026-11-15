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

// Wisp --render-styles out.png [dark]  (saves a picture of the Style window, for checking the design)
if let i = CommandLine.arguments.firstIndex(of: "--render-styles"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let dark = CommandLine.arguments.contains("dark")
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
