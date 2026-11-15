import AppKit
import WebKit

/// Turns Dictate's call-notes Markdown into a styled HTML page. The notes always follow the same
/// small set of Markdown patterns (headings, bullets, checkboxes, bold, quotes, a rule, transcript
/// lines), so a focused converter is enough.
enum NotesRenderer {

    static func html(fromMarkdown md: String, title: String) -> String {
        var body = ""
        var inList = false
        var inTranscript = false
        var afterTitle = false

        func closeList() { if inList { body += "</ul>\n"; inList = false } }

        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { closeList(); continue }

            if line.hasPrefix("# ") {
                closeList()
                body += "<h1>\(inline(String(line.dropFirst(2))))</h1>\n"
                afterTitle = true
                continue
            }
            if line.hasPrefix("## ") {
                closeList()
                let text = String(line.dropFirst(3))
                if text.lowercased().contains("transcript") {
                    inTranscript = true
                    body += "<details class=\"transcript\"><summary>\(escape(text))</summary>\n"
                } else {
                    body += "<h2>\(inline(text))</h2>\n"
                }
                continue
            }
            if line == "---" { closeList(); if !inTranscript { body += "<hr>\n" }; continue }

            // Transcript line: **[00:07] Them:** text
            if let m = line.range(of: #"^\*\*\[([0-9:]+)\] (Me|Them):\*\* ?(.*)$"#, options: .regularExpression) {
                let s = String(line[m])
                let parts = s.replacingOccurrences(of: #"^\*\*\[([0-9:]+)\] (Me|Them):\*\* ?"#, with: "$1|$2|",
                                                   options: .regularExpression)
                    .split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                if parts.count == 3 {
                    let who = parts[1]
                    body += "<div class=\"line \(who.lowercased())\"><span class=\"time\">\(parts[0])</span>"
                        + "<span class=\"who\">\(who == "Me" ? "Me" : "Them")</span>"
                        + "<span class=\"said\">\(inline(parts[2]))</span></div>\n"
                    continue
                }
            }

            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                if !inList { body += "<ul class=\"tasks\">\n"; inList = true }
                let done = !line.hasPrefix("- [ ] ")
                body += "<li><label><input type=\"checkbox\"\(done ? " checked" : "")> <span>\(inline(String(line.dropFirst(6))))</span></label></li>\n"
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !inList { body += "<ul>\n"; inList = true }
                body += "<li>\(inline(String(line.dropFirst(2))))</li>\n"
                continue
            }
            closeList()
            if line.hasPrefix("> ") {
                body += "<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>\n"
                continue
            }
            if afterTitle {
                body += "<p class=\"meta\">\(inline(line))</p>\n"
                afterTitle = false
                continue
            }
            body += "<p>\(inline(line))</p>\n"
        }
        closeList()
        if inTranscript { body += "</details>\n" }

        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(css)</style></head>
        <body><main>
        <div class="brand"><svg viewBox="0 0 100 100" aria-hidden="true"><circle cx="50" cy="50" r="50" fill="#e11d3c"/><path d="M26 31 L38 71 L50 47 L62 71 L74 31" fill="none" stroke="#fff" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/></svg><span>Call Notes</span></div>
        \(body)
        </main></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ s: String) -> String {
        var t = escape(s)
        t = t.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        return t
    }

    private static let css = """
    :root { --bg:#ffffff; --fg:#1d1d1f; --muted:#6e6e73; --line:#e5e5ea; --card:#f5f5f7; --red:#e11d3c;
            --me:#e11d3c; --them:#2563eb; color-scheme: light dark; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#1c1c1e; --fg:#f2f2f7; --muted:#a1a1aa; --line:#38383a; --card:#2c2c2e; --me:#ff5a6e; --them:#6ea8ff; }
    }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--fg);
           font: 15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
    main { max-width: 760px; margin: 0 auto; padding: 28px 32px 60px; }
    .brand { display:flex; align-items:center; gap:8px; color:var(--muted); font-size:12px; font-weight:600;
             letter-spacing:.06em; text-transform:uppercase; margin-bottom:6px; }
    .brand svg { width:18px; height:18px; }
    h1 { font-size: 26px; line-height:1.2; margin: 4px 0 6px; letter-spacing:-.01em; }
    .meta { color: var(--muted); font-size: 13px; margin: 0 0 22px; }
    .meta strong { color: var(--fg); font-weight: 600; }
    h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .07em; color: var(--red);
         margin: 26px 0 8px; padding-top: 18px; border-top: 1px solid var(--line); }
    p { margin: 0 0 10px; }
    ul { margin: 0 0 10px; padding-left: 20px; }
    li { margin: 4px 0; }
    ul.tasks { list-style: none; padding-left: 0; }
    ul.tasks li { background: var(--card); border-radius: 10px; padding: 9px 12px; margin: 6px 0; }
    ul.tasks label { display:flex; gap:10px; align-items:flex-start; cursor:pointer; }
    ul.tasks input { margin-top: 4px; accent-color: var(--red); width:15px; height:15px; flex:none; }
    ul.tasks input:checked + span { text-decoration: line-through; color: var(--muted); }
    blockquote { margin: 14px 0; padding: 10px 14px; border-left: 3px solid var(--red); background: var(--card);
                 border-radius: 0 8px 8px 0; color: var(--muted); }
    hr { border: 0; border-top: 1px solid var(--line); margin: 28px 0 0; }
    details.transcript { margin-top: 28px; border-top: 1px solid var(--line); padding-top: 16px; }
    details.transcript summary { cursor: pointer; font-size: 13px; text-transform: uppercase; letter-spacing: .07em;
                                 color: var(--muted); font-weight: 600; margin-bottom: 10px; }
    .line { display: grid; grid-template-columns: 52px 46px 1fr; gap: 8px; padding: 6px 0;
            border-bottom: 1px solid var(--line); font-size: 14px; }
    .line .time { color: var(--muted); font-variant-numeric: tabular-nums; font-size: 12px; padding-top: 2px; }
    .line .who { font-weight: 700; font-size: 12px; padding-top: 2px; }
    .line.me .who { color: var(--me); }
    .line.them .who { color: var(--them); }
    code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--card); padding: 1px 5px; border-radius: 4px; }
    @media (max-width: 520px) { main { padding: 20px 16px 40px; } .line { grid-template-columns: 44px 1fr; }
      .line .who { display:none; } }
    """
}

/// A window that shows one call's notes, with Copy / Browser / Finder buttons.
final class NotesWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [NotesWindowController] = []
    private let fileURL: URL
    private let markdown: String
    private let html: String

    static func show(_ url: URL) {
        guard let md = try? String(contentsOf: url, encoding: .utf8) else {
            NSWorkspace.shared.open(url)
            return
        }
        if let existing = open.first(where: { $0.fileURL == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = NotesWindowController(url: url, markdown: md)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(url: URL, markdown: String) {
        fileURL = url
        self.markdown = markdown
        let title = CallNotes.extractTitle(markdown) ?? "Call Notes"
        html = NotesRenderer.html(fromMarkdown: markdown, title: title)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.minSize = NSSize(width: 480, height: 420)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let web = WKWebView(frame: .zero)
        web.setValue(false, forKey: "drawsBackground")
        web.loadHTMLString(html, baseURL: nil)

        let bar = NSStackView(views: [
            button("Copy Notes", "doc.on.doc", #selector(copyNotes)),
            button("Open in Browser", "safari", #selector(openInBrowser)),
            button("Show in Finder", "folder", #selector(showInFinder)),
        ])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [bar, divider, web])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        bar.setHuggingPriority(.required, for: .vertical)
        web.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            web.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView = stack
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
                         target: self, action: action)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        return b
    }

    /// Copies the notes (without the long transcript) as plain text, ready for email or Slack.
    @objc private func copyNotes() {
        var notes = markdown
        if let r = notes.range(of: "\n---\n\n## Full Transcript") { notes = String(notes[..<r.lowerBound]) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notes.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        window?.title = (CallNotes.extractTitle(markdown) ?? "Call Notes") + " (copied)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.window?.title = CallNotes.extractTitle(self.markdown) ?? "Call Notes"
        }
    }

    @objc private func openInBrowser() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate-notes-html")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".html")
        try? html.write(to: out, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(out)
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}
