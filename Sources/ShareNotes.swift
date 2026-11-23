import AppKit
import CryptoKit

/// Uploads a call's notes (without the transcript) to webit365.com/notes/<code> so they can be
/// shared with a link. Sharing the same notes again updates that page and keeps the same link.
enum NotesSharer {
    static let endpoint = URL(string: "https://webit365.com/api/notes")!

    static func share(markdown: String, fileURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let key = Keychain.shareKey() else {
            completion(.failure(DictateError("No share key on this Mac yet.")))
            return
        }
        let notes = notesOnly(markdown)
        let title = CallNotes.extractTitle(markdown) ?? "Call Notes"
        let html = NotesRenderer.html(fromMarkdown: notes, title: title)
        let source = SHA256.hash(data: Data("\(NSUserName())|\(fileURL.lastPathComponent)".utf8))
            .map { String(format: "%02x", $0) }.joined()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-wisp-key")
        let payload: [String: Any] = ["title": title, "html": html, "source_id": source,
                                      "shared_by": NSFullUserName()]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if status == 200, let s = json?["url"] as? String, let url = URL(string: s) {
                    result = .success(url)
                } else if status == 401 {
                    result = .failure(DictateError("The share key on this Mac wasn't accepted."))
                } else {
                    let msg = json?["error"] as? String ?? "The server answered \(status)."
                    result = .failure(DictateError("Couldn't share the notes. \(msg)"))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Shares, copies the link, and shows an alert if it fails. Asks for the share key the first time.
    /// `done` gets true when the link is on the clipboard.
    static func shareAndCopy(markdown: String, fileURL: URL, window: NSWindow?, done: @escaping (Bool) -> Void) {
        guard Keychain.shareKey() != nil || askForShareKey() else { done(false); return }
        share(markdown: markdown, fileURL: fileURL) { result in
            switch result {
            case .success(let url):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                done(true)
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "Couldn't share these notes"
                alert.informativeText = error.localizedDescription
                if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                done(false)
            }
        }
    }

    /// First share on a Mac: asks for the team's share key and saves it in the Keychain.
    private static func askForShareKey() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Share key needed"
        alert.informativeText = "Sharing puts these notes (without the transcript) on a private webit365.com link. Paste the Wisp share key you were given. It's saved in this Mac's Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && Keychain.saveShareKey(key)
    }

    /// The notes without the long transcript (the same text Copy Notes copies).
    static func notesOnly(_ markdown: String) -> String {
        guard let r = markdown.range(of: "\n---\n\n## Full Transcript") else { return markdown }
        return String(markdown[..<r.lowerBound])
    }
}

extension Keychain {
    /// The webit365.com share key, saved with `security add-generic-password -s wisp-share-key`.
    static func shareKey() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-a", NSUserName(), "-s", "wisp-share-key", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let key = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty == false) ? key : nil
    }

    static func saveShareKey(_ key: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["add-generic-password", "-U", "-a", NSUserName(), "-s", "wisp-share-key", "-w", key]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
