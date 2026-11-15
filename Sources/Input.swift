import AppKit

/// Push-to-talk: hold the chosen key to record, let go to transcribe.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fired if another key is typed while the hotkey is held (it was used as a normal modifier).
    var onCancel: (() -> Void)?

    private var monitors: [Any] = []
    private var held = false

    func start() {
        stop()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] in self?.flags($0) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] in self?.flags($0); return $0 }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in self?.keyTyped() }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        held = false
    }

    private func flags(_ e: NSEvent) {
        let hk = Settings.shared.hotkey
        guard e.keyCode == hk.keyCode else { return }
        let down = hk.isDown(e.modifierFlags)
        if down && !held {
            held = true
            onPress?()
        } else if !down && held {
            held = false
            onRelease?()
        }
    }

    private func keyTyped() {
        guard held else { return }
        held = false
        onCancel?()
    }
}

enum Paster {
    /// Puts the text on the clipboard, presses ⌘V in the frontmost app,
    /// then puts back whatever was on the clipboard before.
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}

enum History {
    /// Local log so nothing you dictate is ever lost. Lives only on this Mac.
    static func append(raw: String, cleaned: String, app: String?, engine: String, seconds: Double, note: String?) {
        var entry: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "app": app ?? "",
            "engine": engine,
            "audio_seconds": (seconds * 10).rounded() / 10,
            "raw": raw,
            "cleaned": cleaned,
        ]
        if let note { entry["note"] = note }
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let url = Settings.historyURL
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }
}
