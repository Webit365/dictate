import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case idle, recording, working }

    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private let hotkey = HotkeyMonitor()
    private var state: State = .idle { didSet { updateIcon() } }
    private var pressedAt = Date()
    private var targetApp: String?
    private var targetCategory: StyleCategory = .other
    private var lastText: String?
    private var statusNote: String?
    private var accessibilityTimer: Timer?
    private let callRecorder = CallRecorder()
    private var callApp: String?
    private var callStatus: String? { didSet { syncHead() } }   // set while a finished call is being processed
    private let head = HeadModel()
    private var headPanel: FloatingPanel?
    private var callTimer: Timer?
    private var installer: ModelInstaller?
    private var lastNotesURL: URL? {
        get { UserDefaults.standard.string(forKey: "lastNotes").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "lastNotes") }
    }
    private var setupStatus: String? { didSet { syncHead() } }
    private var setupFailed = false
    private var modelsReady: Bool { ModelInstaller.missing.isEmpty }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.ensureSupportFiles()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        recorder.onLevel = { [weak self] rms in
            let level = CGFloat(min(1, rms.squareRoot() * 3.2))
            DispatchQueue.main.async { self?.head.level = level }
        }
        head.onToggleNotes = { [weak self] in
            guard let self else { return }
            if self.callRecorder.isRecording { self.stopCall() } else { self.startCall() }
        }
        head.onHide = { [weak self] in self?.setHeadVisible(false) }
        setHeadVisible(Settings.shared.showHead)
        downloadModelsIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, Settings.shared.engine == .claude || Settings.shared.summaryEngine.model != nil,
                  Keychain.anthropicKey() == nil else { return }
            self.promptForAPIKey(firstRun: true)
        }

        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        hotkey.start()

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            // Key monitoring only starts working once Accessibility is granted; re-arm when it is.
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard AXIsProcessTrusted() else { return }
                t.invalidate()
                self?.hotkey.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        transcriber.shutdown()
    }

    // MARK: Dictation flow

    private func startRecording() {
        guard state == .idle, !callRecorder.isRecording else { return }
        guard modelsReady else {
            statusNote = setupStatus.map { "Still setting up: \($0)" } ?? "The speech model is missing. Use 🎤 → Retry Model Download."
            NSSound(named: "Funk")?.play()
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            statusNote = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        }
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        targetCategory = StyleCategory.current()
        do {
            try recorder.start()
        } catch {
            statusNote = error.localizedDescription
            return
        }
        pressedAt = Date()
        state = .recording
        NSSound(named: "Tink")?.play()
        transcriber.preload()
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()
        state = .idle
    }

    private func finishRecording() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        let seconds = Double(samples.count) / 16000
        // Ignore taps and silence (Whisper invents words like "Thank you." from silence).
        guard Date().timeIntervalSince(pressedAt) > 0.35, seconds > 0.3, AudioFile.rms(samples) > 0.002 else {
            state = .idle
            return
        }
        state = .working
        let app = targetApp
        let category = targetCategory
        let vocab = Settings.vocabulary()
        let engine = Settings.shared.engine

        transcriber.transcribe(samples, vocabulary: vocab) { [weak self] result in
            guard let self else { return }
            let raw: String
            switch result {
            case .success(let t): raw = t
            case .failure(let e):
                DispatchQueue.main.async { self.statusNote = e.localizedDescription; self.state = .idle }
                return
            }
            guard !raw.isEmpty else {
                DispatchQueue.main.async { self.state = .idle }
                return
            }
            Cleaner.clean(raw, targetApp: app, category: category, vocabulary: vocab) { cleanResult in
                var finalText = raw
                var note: String?
                switch cleanResult {
                case .success(let t) where !t.isEmpty: finalText = t
                case .success: note = nil  // engine judged it empty (just filler); keep raw so nothing is lost
                case .failure(let e): note = "Cleanup failed, pasted raw text: " + e.localizedDescription
                }
                History.append(raw: raw, cleaned: finalText, app: app, engine: engine.rawValue,
                               seconds: seconds, note: note)
                DispatchQueue.main.async {
                    self.lastText = finalText
                    if AXIsProcessTrusted() {
                        Paster.paste(finalText)
                        self.statusNote = note
                    } else {
                        // Without Accessibility, macOS silently drops the ⌘V. Leave the text on the
                        // clipboard and say so, instead of losing it.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(finalText, forType: .string)
                        NSSound(named: "Funk")?.play()
                        self.statusNote = "Accessibility permission is off, so Wisp can't paste. Your text is on the clipboard: press ⌘V. Fix: System Settings → Privacy & Security → Accessibility."
                        self.showAccessibilityAlert()
                    }
                    self.state = .idle
                }
            }
        }
    }

    private var alertShown = false
    private func showAccessibilityAlert() {
        guard !alertShown else { return }
        alertShown = true
        let a = NSAlert()
        a.messageText = "Wisp needs Accessibility permission to paste"
        a.informativeText = "Your text is on the clipboard, so you can press ⌘V now.\n\nTo fix it for good: in Privacy & Security → Accessibility, select Wisp and remove it with the – button, then add it back with + (it's in your home folder's Applications folder) and turn it on."
        a.addButton(withTitle: "Open Accessibility Settings")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { openAXSettings() }
        alertShown = false
    }

    // MARK: Menu bar

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let (symbol, tint): (String, NSColor?) = {
            if callRecorder.isRecording && state == .idle { return ("record.circle", .systemRed) }
            if callStatus != nil && state == .idle { return ("doc.text.magnifyingglass", .systemBlue) }
            switch state {
            case .idle: return ("mic", nil)
            case .recording: return ("mic.fill", .systemRed)
            case .working: return ("waveform", .systemBlue)
            }
        }()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Wisp")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        syncHead()
    }

    // MARK: First-run setup

    private func downloadModelsIfNeeded() {
        guard !modelsReady, installer == nil else { return }
        setupFailed = false
        let inst = ModelInstaller()
        inst.onProgress = { [weak self] msg in self?.setupStatus = msg }
        inst.onDone = { [weak self] error in
            guard let self else { return }
            self.installer = nil
            self.setupStatus = nil
            if let error {
                self.setupFailed = true
                self.statusNote = "Model download failed: \(error.localizedDescription)"
            } else {
                self.statusNote = nil
                NSSound(named: "Glass")?.play()
            }
        }
        installer = inst
        inst.start()
    }

    @objc private func retryDownload() { downloadModelsIfNeeded() }

    @objc private func setAPIKey() { promptForAPIKey(firstRun: false) }

    private func promptForAPIKey(firstRun: Bool) {
        let alert = NSAlert()
        alert.messageText = firstRun ? "Welcome to Wisp" : "Anthropic API Key"
        alert.informativeText = (firstRun
            ? "Wisp uses Claude to clean up your dictation and write call notes. Paste the Anthropic API key you were given (it starts with sk-ant-). It's stored in your Mac's Keychain.\n\nYou can skip this and use Wisp without cleanup, then add a key later from the menu."
            : "Paste an Anthropic API key (it starts with sk-ant-). It's stored in your Mac's Keychain.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: firstRun ? "Skip for Now" : "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            if firstRun && Keychain.anthropicKey() == nil { Settings.shared.engine = .none }
            return
        }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-ant-") else {
            statusNote = "That doesn't look like an Anthropic API key (it should start with sk-ant-)."
            return
        }
        guard Keychain.saveAnthropicKey(key) else {
            statusNote = "Couldn't save the key to the Keychain."
            return
        }
        if Settings.shared.engine == .none { Settings.shared.engine = .claude }
        Keychain.validate(key) { [weak self] ok, msg in
            self?.statusNote = ok ? nil : msg
            if ok { NSSound(named: "Glass")?.play() }
        }
    }

    // MARK: Floating head

    private func syncHead() {
        switch state {
        case .idle: head.mode = .idle
        case .recording: head.mode = .listening
        case .working: head.mode = .thinking
        }
        if state != .recording { head.level = 0 }
        head.callRecording = callRecorder.isRecording
        head.callBusy = callStatus
        head.setup = setupStatus.map { s in
            let pct = s.split(separator: " ").last.map(String.init) ?? ""
            return pct.hasSuffix("%") ? "Setting up \(pct)" : "Setting up"
        }
        if callRecorder.isRecording {
            if callTimer == nil {
                head.callSeconds = 0
                callTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self, let start = self.callRecorder.startedAt else { return }
                    self.head.callSeconds = Int(Date().timeIntervalSince(start))
                }
            }
        } else {
            callTimer?.invalidate()
            callTimer = nil
        }
    }

    private func setHeadVisible(_ visible: Bool) {
        Settings.shared.showHead = visible
        if visible {
            if headPanel == nil { headPanel = FloatingPanel(model: head) }
            headPanel?.orderFrontRegardless()
        } else {
            headPanel?.orderOut(nil)
        }
    }

    @objc private func toggleHead() { setHeadVisible(!Settings.shared.showHead) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        if let s = setupStatus { menu.addItem(disabled("⬇︎ First-time setup: " + s)) }
        if setupFailed { menu.addItem(item("Retry Model Download", #selector(retryDownload))) }

        let headline: String
        switch state {
        case .idle: headline = "Hold \(s.hotkey.title) to dictate"
        case .recording: headline = "Listening…"
        case .working: headline = "Cleaning up…"
        }
        menu.addItem(disabled(headline))
        if let note = statusNote { menu.addItem(disabled("⚠︎ " + note)) }

        // Call notes
        if callRecorder.isRecording {
            let secs = Int(Date().timeIntervalSince(callRecorder.startedAt ?? Date()))
            menu.addItem(disabled("🔴 Recording call · \(CallNotes.clock(Double(secs)))"))
            menu.addItem(item("Stop & Write Call Notes", #selector(stopCall)))
            menu.addItem(item("Discard This Recording", #selector(discardCall)))
        } else if let cs = callStatus {
            menu.addItem(disabled("📝 " + cs))
        } else {
            menu.addItem(item("Start Call Notes", #selector(startCall)))
        }
        if let last = lastNotesURL, FileManager.default.fileExists(atPath: last.path), !callRecorder.isRecording {
            menu.addItem(item("Show Last Call Notes", #selector(showLastNotes)))
        }
        menu.addItem(.separator())

        let copy = item("Copy Last Dictation", #selector(copyLast))
        copy.isEnabled = lastText != nil
        menu.addItem(copy)
        menu.addItem(.separator())

        // Cleanup engine
        let cleanup = NSMenu()
        for e in CleanupEngine.allCases {
            let i = item(e.title, #selector(pickEngine(_:)))
            i.representedObject = e.rawValue
            i.state = s.engine == e ? .on : .off
            cleanup.addItem(i)
        }
        cleanup.addItem(.separator())
        cleanup.addItem(disabled("Claude model:"))
        for m in ClaudeModel.allCases {
            let i = item("   " + m.title, #selector(pickModel(_:)))
            i.representedObject = m.rawValue
            i.state = s.claudeModel == m ? .on : .off
            cleanup.addItem(i)
        }
        let cleanupItem = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
        cleanupItem.submenu = cleanup
        menu.addItem(cleanupItem)

        // Hotkey
        let keys = NSMenu()
        for h in Hotkey.allCases {
            let i = item(h.title, #selector(pickHotkey(_:)))
            i.representedObject = h.rawValue
            i.state = s.hotkey == h ? .on : .off
            keys.addItem(i)
        }
        let keysItem = NSMenuItem(title: "Dictation Key", action: nil, keyEquivalent: "")
        keysItem.submenu = keys
        menu.addItem(keysItem)

        // Call notes settings
        let callMenu = NSMenu()
        callMenu.addItem(disabled("Notes written by:"))
        for e in SummaryEngine.allCases {
            let i = item("   " + e.title, #selector(pickSummary(_:)))
            i.representedObject = e.rawValue
            i.state = s.summaryEngine == e ? .on : .off
            callMenu.addItem(i)
        }
        callMenu.addItem(.separator())
        callMenu.addItem(disabled("Saving to: " + s.notesFolder.lastPathComponent))
        callMenu.addItem(item("Choose Notes Folder…", #selector(chooseNotesFolder)))
        callMenu.addItem(item("Open Notes Folder", #selector(openNotesFolder)))
        callMenu.addItem(item("Open Call Recordings (audio)", #selector(openRecordings)))
        let callItem = NSMenuItem(title: "Call Notes Settings", action: nil, keyEquivalent: "")
        callItem.submenu = callMenu
        menu.addItem(callItem)

        menu.addItem(item(Keychain.anthropicKey() == nil ? "Set Anthropic API Key… (needed for Claude)" : "Change Anthropic API Key…",
                          #selector(setAPIKey)))
        menu.addItem(item("Style…", #selector(showStyles)))
        menu.addItem(item("Edit Vocabulary…", #selector(editVocabulary)))
        menu.addItem(item("Open Dictation History", #selector(openHistory)))
        menu.addItem(.separator())

        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        if !mic { menu.addItem(item("Microphone: needs permission…", #selector(openMicSettings))) }
        if !ax { menu.addItem(item("Accessibility: needs permission…", #selector(openAXSettings))) }
        if mic && ax { menu.addItem(disabled("Permissions: all set")) }

        let headItem = item("Show Floating Head", #selector(toggleHead))
        headItem.state = s.showHead ? .on : .off
        menu.addItem(headItem)

        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Wisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: Call notes

    @objc private func startCall() {
        guard !callRecorder.isRecording, callStatus == nil else { return }
        guard modelsReady else { statusNote = "Wait for first-time setup to finish before recording calls."; return }
        callApp = CallApp.detect()
        callRecorder.start { [weak self] error in
            guard let self else { return }
            if let error {
                self.statusNote = error.localizedDescription
            } else {
                self.statusNote = "Recording the call. Let everyone know you're recording."
                NSSound(named: "Tink")?.play()
            }
            self.updateIcon()
        }
    }

    @objc private func stopCall() {
        guard callRecorder.isRecording else { return }
        if callApp == nil { callApp = CallApp.detect() }
        callStatus = "Finishing recording…"
        statusNote = nil
        updateIcon()
        callRecorder.stop { [weak self] folder, duration in
            guard let self, let folder else { self?.callStatus = nil; self?.updateIcon(); return }
            CallNotes.process(folder: folder, duration: duration, app: self.callApp, transcriber: self.transcriber,
                              status: { msg in DispatchQueue.main.async { self.callStatus = msg } }) { result in
                DispatchQueue.main.async {
                    self.callStatus = nil
                    switch result {
                    case .success(let url):
                        NSSound(named: "Glass")?.play()
                        self.lastNotesURL = url
                        NotesWindowController.show(url)
                        self.statusNote = nil
                    case .failure(let e):
                        self.statusNote = "Call notes: " + e.localizedDescription
                    }
                    self.updateIcon()
                }
            }
        }
    }

    @objc private func discardCall() {
        guard callRecorder.isRecording else { return }
        callRecorder.stop { [weak self] folder, _ in
            if let folder { try? FileManager.default.removeItem(at: folder) }
            self?.statusNote = "Recording discarded."
            self?.updateIcon()
        }
    }

    @objc private func showLastNotes() {
        if let url = lastNotesURL { NotesWindowController.show(url) }
    }

    @objc private func pickSummary(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let e = SummaryEngine(rawValue: raw) { Settings.shared.summaryEngine = e }
    }

    @objc private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Notes Here"
        panel.directoryURL = Settings.shared.notesFolder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { Settings.shared.notesFolder = url }
    }

    @objc private func openNotesFolder() {
        try? FileManager.default.createDirectory(at: Settings.shared.notesFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.shared.notesFolder)
    }

    @objc private func openRecordings() {
        try? FileManager.default.createDirectory(at: Settings.callsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.callsDir)
    }

    @objc private func copyLast() {
        guard let t = lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }
    @objc private func pickEngine(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let e = CleanupEngine(rawValue: raw) { Settings.shared.engine = e }
        statusNote = nil
    }
    @objc private func pickModel(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = ClaudeModel(rawValue: raw) { Settings.shared.claudeModel = m }
    }
    @objc private func pickHotkey(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let h = Hotkey(rawValue: raw) { Settings.shared.hotkey = h }
        hotkey.start()
    }
    @objc private func showStyles() { StylesWindowController.show() }

    @objc private func editVocabulary() {
        Settings.ensureSupportFiles()
        NSWorkspace.shared.open(Settings.vocabularyURL)
    }
    @objc private func openHistory() {
        if !FileManager.default.fileExists(atPath: Settings.historyURL.path) {
            FileManager.default.createFile(atPath: Settings.historyURL.path, contents: nil)
        }
        NSWorkspace.shared.open(Settings.historyURL)
    }
    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
    @objc private func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            statusNote = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
    }
}

/// `Dictate --test-call folder`: runs call-notes processing on a folder holding me.caf / them.caf.
enum CallTestRunner {
    static func run(folder: String) -> Never {
        Settings.ensureSupportFiles()
        let sem = DispatchSemaphore(value: 0)
        let t0 = Date()
        var lastStatus = ""
        let transcriber = Transcriber()
        CallNotes.process(folder: URL(fileURLWithPath: folder), duration: 120, app: "Zoom", transcriber: transcriber,
                          status: { msg in
                              let base = msg.components(separatedBy: "…").first ?? msg
                              if base != lastStatus { print("· \(base)"); lastStatus = base }
                          }) { r in
            switch r {
            case .success(let url): print("saved (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s): \(url.path)")
            case .failure(let e): print("error: \(e.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
        transcriber.shutdown()
        exit(0)
    }
}

/// `Dictate --test file.wav`: runs the same transcribe + cleanup pipeline on a file and prints timings.
enum TestRunner {
    static func run(path: String) -> Never {
        Settings.ensureSupportFiles()
        let vocab = Settings.vocabulary()
        do {
            let samples = try AudioFile.load16kMono(URL(fileURLWithPath: path))
            print("audio: \(String(format: "%.1f", Double(samples.count) / 16000)) s")
            let t = Transcriber()
            let sem = DispatchSemaphore(value: 0)
            var raw = ""
            var t0 = Date()
            t.transcribe(samples, vocabulary: vocab) { r in
                switch r {
                case .success(let s): raw = s
                case .failure(let e): print("whisper error: \(e.localizedDescription)")
                }
                sem.signal()
            }
            sem.wait()
            print("whisper first run (\(String(format: "%.2f", Date().timeIntervalSince(t0))) s, includes model load):\n  \(raw)")
            t0 = Date()
            t.transcribe(samples, vocabulary: vocab) { _ in sem.signal() }
            sem.wait()
            print("whisper warm run: \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
            t0 = Date()
            let engine = Settings.shared.engine
            Cleaner.clean(raw, targetApp: "Mail", vocabulary: vocab) { r in
                switch r {
                case .success(let s): print("cleanup [\(engine.rawValue)/\(Settings.shared.claudeModel.rawValue)] (\(String(format: "%.2f", Date().timeIntervalSince(t0))) s):\n  \(s)")
                case .failure(let e): print("cleanup error: \(e.localizedDescription)")
                }
                sem.signal()
            }
            sem.wait()
            t.shutdown()
            exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }
}
