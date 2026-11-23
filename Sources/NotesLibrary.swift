import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Notes library: every saved call note, shown as a tab in the Wisp window

struct NoteItem: Identifiable, Equatable {
    let url: URL
    let title: String
    let date: Date
    let markdown: String
    var id: URL { url }

    /// The notes without the long transcript, ready for email or Slack.
    var notesOnly: String {
        var notes = markdown
        if let r = notes.range(of: "\n---\n\n## Full Transcript") { notes = String(notes[..<r.lowerBound]) }
        return notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First line of the summary, for the list.
    var snippet: String {
        let lines = markdown.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## summary" }),
           let s = lines[(i + 1)...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return s.replacingOccurrences(of: "**", with: "")
        }
        return ""
    }
}

final class NotesLibrary: ObservableObject {
    static let shared = NotesLibrary()

    @Published private(set) var items: [NoteItem] = []
    @Published var selected: URL?
    @Published var query = ""
    weak var webView: WKWebView?

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?

    var filtered: [NoteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        let words = q.split(separator: " ").map(String.init)
        return items.filter { item in
            let hay = (item.title + "\n" + item.markdown).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var current: NoteItem? { items.first { $0.url == selected } }

    func reload() {
        let dir = Settings.shared.notesFolder
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        var found: [NoteItem] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let md = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            let date = v?.creationDate ?? v?.contentModificationDate ?? .distantPast
            let title = CallNotes.extractTitle(md) ?? url.deletingPathExtension().lastPathComponent
            found.append(NoteItem(url: url, title: title, date: date, markdown: md))
        }
        found.sort { $0.date > $1.date }
        items = found
        if selected == nil || !found.contains(where: { $0.url == selected }) { selected = found.first?.url }
        watch(dir)
    }

    /// Reloads by itself when a note is added, renamed or removed in the folder.
    private func watch(_ dir: URL) {
        guard watchedPath != dir.path else { return }
        watcher?.cancel()
        watcher = nil
        watchedPath = nil
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            // Give the writer a moment to finish the file.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.reload() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
        watchedPath = dir.path
    }

    // MARK: Actions

    func copy(_ item: NoteItem, withTranscript: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(withTranscript ? item.markdown : item.notesOnly, forType: .string)
    }

    func saveCopy(_ item: NoteItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.canCreateDirectories = true
        panel.message = "Save a copy of these call notes"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let out = panel.url else { return }
        try? item.markdown.write(to: out, atomically: true, encoding: .utf8)
    }

    /// The standard print sheet, which also has "Save as PDF".
    func printOrPDF() {
        guard let web = webView, let window = web.window else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        let op = web.printOperation(with: info)
        op.view?.frame = web.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func showInFinder(_ item: NoteItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func openFolder() {
        try? FileManager.default.createDirectory(at: Settings.shared.notesFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.shared.notesFolder)
    }
}

// MARK: - Views

struct NotesLibraryView: View {
    @ObservedObject var lib = NotesLibrary.shared
    @ObservedObject var auto = AutoStartSetting.shared
    @Environment(\.colorScheme) private var scheme
    @State private var copied: String?
    @State private var sharing = false

    private let red = Color(red: 0xE1 / 255.0, green: 0x1D / 255.0, blue: 0x3C / 255.0)

    var body: some View {
        VStack(spacing: 14) {
            autoStartBar
            HStack(spacing: 0) {
                sidebar.frame(width: 290)
                Divider()
                detail
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme == .dark ? Color(white: 0.15) : .white))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.10)))
        }
        .onAppear { lib.reload() }
    }

    /// On/off switch for starting notes by itself when a call begins.
    private var autoStartBar: some View {
        HStack(spacing: 14) {
            Image(systemName: auto.isOn ? "phone.badge.waveform.fill" : "phone.fill")
                .font(.system(size: 16))
                .foregroundColor(auto.isOn ? red : .secondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill((auto.isOn ? red : Color.primary).opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-start notes when a call begins")
                    .font(.system(size: 14, weight: .semibold))
                Text(auto.isOn
                     ? "On: Zoom, Teams, Slack, FaceTime, phone calls and Google Meet. Notes are written when the call ends."
                     : "Off: click Notes on the floating W to record a call yourself.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $auto.isOn)
                .toggleStyle(.switch)
                .tint(red)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(scheme == .dark ? Color(white: 0.15) : .white))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.10)))
    }

    // List of notes with search
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search notes", text: $lib.query).textFieldStyle(.plain)
                if !lib.query.isEmpty {
                    Button { lib.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .padding(12)

            if lib.filtered.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(lib.items.isEmpty ? "No call notes yet" : "No notes match")
                        .font(.system(size: 14, weight: .medium))
                    if lib.items.isEmpty {
                        Text("Click Notes on the Wisp widget to record a call. Finished notes show up here.")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(lib.filtered) { row($0) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }

            Divider()
            HStack {
                Text("\(lib.items.count) note\(lib.items.count == 1 ? "" : "s") · \(Settings.shared.notesFolder.lastPathComponent)")
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                Button { lib.openFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).foregroundColor(.secondary).help("Open the notes folder")
                Button { lib.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundColor(.secondary).help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func row(_ item: NoteItem) -> some View {
        let isSel = lib.selected == item.url
        return Button { lib.selected = item.url } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    .foregroundColor(isSel ? .white : .primary)
                Text(Self.dateText(item.date)).font(.system(size: 11))
                    .foregroundColor(isSel ? .white.opacity(0.85) : .secondary)
                if !item.snippet.isEmpty {
                    Text(item.snippet).font(.system(size: 12)).lineLimit(2)
                        .foregroundColor(isSel ? .white.opacity(0.9) : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSel ? red : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Notes") { lib.copy(item, withTranscript: false) }
            Button("Copy Notes + Transcript") { lib.copy(item, withTranscript: true) }
            Button("Share Link") { share(item) }
            Button("Save a Copy…") { lib.saveCopy(item) }
            Divider()
            Button("Open in Its Own Window") { NotesWindowController.show(item.url) }
            Button("Show in Finder") { lib.showInFinder(item) }
        }
    }

    // The selected note, with Copy / Save buttons
    @ViewBuilder private var detail: some View {
        if let item = lib.current {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { copy(item, transcript: false) } label: {
                        Label(copied == "notes" ? "Copied" : "Copy Notes",
                              systemImage: copied == "notes" ? "checkmark" : "doc.on.doc")
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copies the notes without the transcript, ready for email or Slack (⇧⌘C)")
                    Button { copy(item, transcript: true) } label: {
                        Label(copied == "all" ? "Copied" : "Copy + Transcript",
                              systemImage: copied == "all" ? "checkmark" : "text.quote")
                    }
                    Button { share(item) } label: {
                        Label(sharing ? "Sharing…" : (copied == "link" ? "Link Copied" : "Share Link"),
                              systemImage: copied == "link" ? "checkmark" : "link")
                    }
                    .disabled(sharing)
                    .help("Puts the notes (no transcript) on a private webit365.com link and copies it")
                    Menu {
                        Button("Save a Copy (Markdown)…") { lib.saveCopy(item) }
                        Button("Print or Save as PDF…") { lib.printOrPDF() }
                    } label: { Label("Save", systemImage: "square.and.arrow.down") }
                        .fixedSize()
                    Spacer()
                    Button { NotesWindowController.show(item.url) } label: { Image(systemName: "macwindow") }
                        .help("Open in its own window")
                    Button { lib.showInFinder(item) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                NoteWebView(html: NotesRenderer.html(fromMarkdown: item.markdown, title: item.title))
            }
        } else {
            VStack {
                Spacer()
                Image(systemName: "note.text").font(.system(size: 34)).foregroundColor(.secondary.opacity(0.6))
                Text("Pick a note to read it").foregroundColor(.secondary).padding(.top, 6)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func copy(_ item: NoteItem, transcript: Bool) {
        lib.copy(item, withTranscript: transcript)
        let tag = transcript ? "all" : "notes"
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == tag { copied = nil } }
    }

    private func share(_ item: NoteItem) {
        sharing = true
        NotesSharer.shareAndCopy(markdown: item.markdown, fileURL: item.url, window: NSApp.keyWindow) { ok in
            sharing = false
            guard ok else { return }
            copied = "link"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if copied == "link" { copied = nil } }
        }
    }

    private static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
            ? "EEE, MMM d · h:mm a" : "MMM d, yyyy · h:mm a"
        return f.string(from: d)
    }
}

/// Renders one note's HTML.
struct NoteWebView: NSViewRepresentable {
    let html: String

    final class Coordinator { var lastHTML = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.setValue(false, forKey: "drawsBackground")
        NotesLibrary.shared.webView = web
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        NotesLibrary.shared.webView = web
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: nil)
    }
}
