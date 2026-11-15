import AppKit

struct DictateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum CleanupEngine: String, CaseIterable {
    case claude, local, none
    var title: String {
        switch self {
        case .claude: return "Claude (best cleanup)"
        case .local: return "Local AI via Ollama (fully private)"
        case .none: return "No cleanup (raw Whisper text)"
        }
    }
}

enum ClaudeModel: String, CaseIterable {
    case opus = "claude-opus-5-5"
    case haiku = "claude-haiku-5-5"
    var title: String {
        switch self {
        case .opus: return "Opus 5.5 (smartest)"
        case .haiku: return "Haiku 5.5 (fastest, cheapest)"
        }
    }
}

enum SummaryEngine: String, CaseIterable {
    case opus, sonnet, none
    var title: String {
        switch self {
        case .opus: return "Claude Opus 5.5 (best notes)"
        case .sonnet: return "Claude Sonnet 5.5 (faster, cheaper)"
        case .none: return "Transcript only (fully private)"
        }
    }
    var model: String? {
        switch self {
        case .opus: return "claude-opus-5-5"
        case .sonnet: return "claude-sonnet-5-5"
        case .none: return nil
        }
    }
}

enum Hotkey: String, CaseIterable {
    case rightOption, rightCommand, fn
    var title: String {
        switch self {
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .fn: return "Fn / Globe 🌐"
        }
    }
    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .fn: return 63
        }
    }
    /// True when this specific key is down, using device-dependent bits so
    /// the left-hand Option/Command keys don't trigger dictation.
    func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .rightOption: return flags.rawValue & 0x40 != 0      // NX_DEVICERALTKEYMASK
        case .rightCommand: return flags.rawValue & 0x10 != 0     // NX_DEVICERCMDKEYMASK
        case .fn: return flags.contains(.function)
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var engine: CleanupEngine {
        get { CleanupEngine(rawValue: d.string(forKey: "engine") ?? "") ?? .claude }
        set { d.set(newValue.rawValue, forKey: "engine") }
    }
    var claudeModel: ClaudeModel {
        get { ClaudeModel(rawValue: d.string(forKey: "claudeModel") ?? "") ?? .haiku }
        set { d.set(newValue.rawValue, forKey: "claudeModel") }
    }
    var hotkey: Hotkey {
        get { Hotkey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }
    var summaryEngine: SummaryEngine {
        get { SummaryEngine(rawValue: d.string(forKey: "summaryEngine") ?? "") ?? .sonnet }
        set { d.set(newValue.rawValue, forKey: "summaryEngine") }
    }
    /// Where finished call notes (Markdown) are saved. Audio always stays in Application Support.
    var notesFolder: URL {
        get {
            if let p = d.string(forKey: "notesFolder") { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Call Notes")
        }
        set { d.set(newValue.path, forKey: "notesFolder") }
    }
    var showHead: Bool {
        get { d.object(forKey: "showHead") as? Bool ?? true }
        set { d.set(newValue, forKey: "showHead") }
    }
    var ollamaModel: String {
        get { d.string(forKey: "ollamaModel") ?? "gemma3:4b" }
        set { d.set(newValue, forKey: "ollamaModel") }
    }

    // MARK: Files (all local, never synced)

    static let supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dictate")
    static var modelURL: URL { supportDir.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin") }
    static var vadModelURL: URL { supportDir.appendingPathComponent("models/ggml-silero-v6.2.0.bin") }
    static var callsDir: URL { supportDir.appendingPathComponent("calls") }
    static var vocabularyURL: URL { supportDir.appendingPathComponent("vocabulary.txt") }
    static var historyURL: URL { supportDir.appendingPathComponent("history.jsonl") }

    static let defaultVocabulary = """
    # Names and words Dictate should always spell correctly.
    # One per line. Lines starting with # are ignored.
    Covenant Church
    ClickNNY
    Webit365
    Just One More
    Fort Drum
    Watertown
    North Country
    Jefferson County
    Lewis County
    St. Lawrence County
    Ogdensburg
    Thousand Islands
    Tug Hill
    Dreadnought
    Alchemy Seven
    Proclaim
    Remotion
    Supabase
    Vercel
    Restream
    """

    static func ensureSupportFiles() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: vocabularyURL.path) {
            try? defaultVocabulary.write(to: vocabularyURL, atomically: true, encoding: .utf8)
        }
    }

    static func vocabulary() -> [String] {
        guard let text = try? String(contentsOf: vocabularyURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
