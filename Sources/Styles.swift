import AppKit
import SwiftUI

// MARK: - Styles: how formal dictation comes out, per kind of app (like Wispr Flow's Style page)

enum WritingStyle: String, CaseIterable, Identifiable {
    case formal, casual, veryCasual
    var id: String { rawValue }

    var title: String {
        switch self {
        case .formal: return "Formal."
        case .casual: return "Casual"
        case .veryCasual: return "very casual"
        }
    }

    var subtitle: String {
        switch self {
        case .formal: return "Caps + Punctuation"
        case .casual: return "Caps + Less punctuation"
        case .veryCasual: return "No Caps + Less punctuation"
        }
    }

    /// Added to the cleanup prompt. These rules take priority over the general punctuation rule.
    var instruction: String {
        switch self {
        case .formal:
            return "Formal: standard capitalization and full, correct punctuation. End every sentence, "
                + "including the last one, with a period, question mark, or exclamation point."
        case .casual:
            return "Casual: normal capitalization, but light punctuation. Leave out commas that aren't needed "
                + "to understand the sentence (for example after a greeting like \"Hey\"), and leave off the period "
                + "at the very end. Keep question marks and periods between sentences."
        case .veryCasual:
            return "Very casual: write everything in lowercase, including the first word of each sentence, names "
                + "and \"i\" (keep acronyms like NY or PDF in capitals). Use light punctuation: leave out commas "
                + "that aren't needed and leave off the period at the very end. Still end every question with a question "
                + "mark and keep the break between sentences (a question mark or period), just in lowercase."
        }
    }

    /// Applies the parts of the style that don't need judgment, so it holds even when the model slips
    /// (or when cleanup is off).
    func enforce(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        switch self {
        case .formal:
            return t
        case .casual, .veryCasual:
            // Drop a single trailing period (not "..." and not after an abbreviation-looking "etc.").
            if t.hasSuffix("."), !t.hasSuffix(".."), !t.lowercased().hasSuffix("etc.") { t.removeLast() }
            return t
        }
    }

    /// The same sample sentence, shown on each card.
    func sample(for category: StyleCategory) -> String {
        let s = category.sample
        switch self {
        case .formal: return s.formal
        case .casual: return s.casual
        case .veryCasual: return s.veryCasual
        }
    }
}

enum StyleCategory: String, CaseIterable, Identifiable {
    case personal, work, email, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .personal: return "Personal messages"
        case .work: return "Work messages"
        case .email: return "Email"
        case .other: return "Other"
        }
    }

    var banner: String {
        switch self {
        case .personal: return "This style applies in personal messengers"
        case .work: return "This style applies in work messengers"
        case .email: return "This style applies in email"
        case .other: return "This style applies everywhere else"
        }
    }

    var apps: [String] {
        switch self {
        case .personal: return ["Messages", "WhatsApp", "Telegram", "Discord", "Signal", "Messenger", "Instagram"]
        case .work: return ["Slack", "Teams", "Google Chat", "Zoom chat"]
        case .email: return ["Mail", "Outlook", "Gmail", "Spark", "Superhuman"]
        case .other: return ["Docs", "Notes", "Claude", "ChatGPT", "Browsers", "Everything else"]
        }
    }

    var symbol: String {
        switch self {
        case .personal: return "message.fill"
        case .work: return "bubble.left.and.bubble.right.fill"
        case .email: return "envelope.fill"
        case .other: return "doc.text.fill"
        }
    }

    var defaultStyle: WritingStyle {
        switch self {
        case .personal: return .casual
        case .work, .email, .other: return .formal
        }
    }

    var sample: (formal: String, casual: String, veryCasual: String) {
        switch self {
        case .personal:
            return ("Hey, are you free for lunch tomorrow? Let's do 12 if that works for you.",
                    "Hey are you free for lunch tomorrow? Let's do 12 if that works for you",
                    "hey are you free for lunch tomorrow? let's do 12 if that works for you")
        case .work:
            return ("Hey, the client approved the mockups. I'll start on the build today.",
                    "Hey the client approved the mockups. I'll start on the build today",
                    "hey the client approved the mockups. i'll start on the build today")
        case .email:
            return ("Hi Jeff,\n\nThanks for sending the catalog. I'll have the drafts ready by Thursday.",
                    "Hi Jeff\n\nThanks for sending the catalog. I'll have the drafts ready by Thursday",
                    "hi jeff\n\nthanks for sending the catalog. i'll have the drafts ready by thursday")
        case .other:
            return ("The new landing page goes live Monday. Let me know if anything needs to change.",
                    "The new landing page goes live Monday. Let me know if anything needs to change",
                    "the new landing page goes live monday. let me know if anything needs to change")
        }
    }

    // MARK: Which category the app you're typing into belongs to

    private static let personalApps: Set<String> = [
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram",
        "org.telegram.desktop", "com.hnc.Discord", "org.whispersystems.signal-desktop",
        "com.facebook.archon", "com.facebook.archon.developerID",
    ]
    private static let workApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos",
        "com.google.Chat", "Cisco-Systems.Spark",
    ]
    private static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
        "it.bloop.airmail2", "com.mimestream.Mimestream", "com.google.Gmail", "com.canarymail.mac",
    ]

    static func classify(bundleID: String?, windowTitle: String?) -> StyleCategory {
        if let id = bundleID {
            if personalApps.contains(id) { return .personal }
            if workApps.contains(id) { return .work }
            if emailApps.contains(id) { return .email }
        }
        // Web apps in a browser: go by the tab's title.
        let t = (windowTitle ?? "").lowercased()
        if t.isEmpty { return .other }
        if t.contains("gmail") || t.contains("outlook") || t.contains("yahoo mail") || t.contains("proton mail")
            || t.contains("icloud mail") { return .email }
        if t.contains("whatsapp") || t.contains("messenger") || t.contains("discord") || t.contains("instagram")
            || t.contains("telegram") || t.hasPrefix("messages") { return .personal }
        if t.contains("slack") || t.contains("microsoft teams") || t.contains("google chat") { return .work }
        return .other
    }

    /// Category of whatever app is in front right now.
    static func current() -> StyleCategory {
        let app = NSWorkspace.shared.frontmostApplication
        return classify(bundleID: app?.bundleIdentifier, windowTitle: frontWindowTitle(pid: app?.processIdentifier))
    }

    /// Title of the front window of an app (needs Screen & System Audio Recording permission to read
    /// other apps' titles; without it this is just empty and the app is classified by bundle ID).
    private static func frontWindowTitle(pid: pid_t?) -> String? {
        guard let pid,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in info where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty { return name }
        }
        return nil
    }
}

/// Saved choices, one style per category.
final class StyleStore: ObservableObject {
    static let shared = StyleStore()
    private let d = UserDefaults.standard

    @Published private(set) var choices: [StyleCategory: WritingStyle] = [:]

    private init() {
        for c in StyleCategory.allCases {
            choices[c] = d.string(forKey: "style.\(c.rawValue)").flatMap(WritingStyle.init) ?? c.defaultStyle
        }
    }

    func style(for c: StyleCategory) -> WritingStyle { choices[c] ?? c.defaultStyle }

    func set(_ s: WritingStyle, for c: StyleCategory) {
        choices[c] = s
        d.set(s.rawValue, forKey: "style.\(c.rawValue)")
    }
}

// MARK: - Styles window

struct StylesView: View {
    @ObservedObject var store = StyleStore.shared
    @State private var tab: StyleCategory = .personal
    @Environment(\.colorScheme) private var scheme

    private let red = Color(red: 0xE1 / 255.0, green: 0x1D / 255.0, blue: 0x3C / 255.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Style")
                .font(.system(size: 28, weight: .semibold))

            // Tabs
            HStack(spacing: 28) {
                ForEach(StyleCategory.allCases) { c in
                    Button { tab = c } label: {
                        VStack(spacing: 8) {
                            Text(c.title)
                                .font(.system(size: 14, weight: tab == c ? .semibold : .regular))
                                .foregroundColor(tab == c ? .primary : .secondary)
                            Rectangle().fill(tab == c ? Color.primary : .clear).frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .overlay(alignment: .bottom) { Divider() }

            // Banner
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tab.banner)
                        .font(.system(size: 24, weight: .regular, design: .serif))
                        .foregroundColor(.white)
                    Text(tab.apps.joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: tab.symbol)
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.22, green: 0.12, blue: 0.10), red.opacity(0.85),
                                                  Color(red: 0.25, green: 0.22, blue: 0.30)],
                                         startPoint: .leading, endPoint: .trailing))
            )

            // Cards
            HStack(alignment: .top, spacing: 18) {
                ForEach(WritingStyle.allCases) { s in card(s) }
            }

            Text("Wisp picks the style from the app you're dictating into. Spoken words stay the same; only capitals and punctuation change.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(minWidth: 820, minHeight: 600)
        .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.985))
    }

    private func card(_ s: WritingStyle) -> some View {
        let selected = store.style(for: tab) == s
        return Button { store.set(s, for: tab) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.title).font(.system(size: 15, weight: .medium))
                Text(s.subtitle).font(.system(size: 15)).foregroundColor(.primary.opacity(0.85))
                Spacer(minLength: 40)
                Text(s.sample(for: tab))
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(red.opacity(scheme == .dark ? 0.12 : 0.05)))
                HStack {
                    Spacer()
                    Circle()
                        .fill(selected ? red : red.opacity(0.25))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: selected ? "checkmark" : "w.circle")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white.opacity(selected ? 1 : 0.8)))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme == .dark ? Color(white: 0.15) : .white))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? red : Color.primary.opacity(0.10), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}

final class StylesWindowController: NSWindowController {
    private static var shared: StylesWindowController?

    static func show() {
        if shared == nil { shared = StylesWindowController() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Wisp Style"
        window.contentView = NSHostingView(rootView: StylesView())
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}
