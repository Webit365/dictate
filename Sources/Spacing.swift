import AppKit
import ApplicationServices

/// Adds a leading space when a dictation would otherwise butt up against the text before the cursor,
/// e.g. "number nine." + "Open hands" → "number nine. Open hands" instead of "number nine.Open hands".
///
/// Two ways of knowing what's before the cursor:
/// 1. Continuation: if Wisp pasted into this same app and nothing has been typed or clicked since,
///    the cursor is still right after that paste, so we know its last character. This is the
///    common "talk, stop, talk again" case and works in every app, including web editors
///    (ChatGPT, Gmail, Slack) whose text Accessibility can't read reliably.
/// 2. Accessibility: otherwise ask the focused text field for the character before the cursor.
///    If it can't tell us, paste as-is (the old behavior).
enum Spacing {
    private static var lastPasteAt: Date?
    private static var lastPastePID: pid_t?
    private static var lastPasteEnd: Character?
    private static var touchedSince = true
    private static var monitors: [Any] = []

    /// How long a pause still counts as "carrying on" from the last dictation.
    private static let continuationWindow: TimeInterval = 30 * 60

    /// Watch for typing and clicks: either can move the cursor or change the text after a paste.
    /// Safe to call again (e.g. once Accessibility is granted, so key events start arriving).
    static func startWatching() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in noteActivity() }) {
            monitors.append(m)
        }
    }

    private static func noteActivity() {
        // Ignore our own ⌘V, which arrives as a keyDown right after the paste.
        if let t = lastPasteAt, Date().timeIntervalSince(t) < 0.6 { return }
        touchedSince = true
    }

    /// Returns the text to paste, with a leading space added when it's needed.
    static func adjust(_ text: String, pid: pid_t?) -> String {
        guard let first = text.first, !first.isWhitespace else { return text }
        // Punctuation that attaches to the previous word never wants a space before it.
        if ",.;:!?)]}%…’”".contains(first) { return text }

        let before: Character?
        if let pid, pid == lastPastePID, !touchedSince,
           let t = lastPasteAt, Date().timeIntervalSince(t) < continuationWindow {
            before = lastPasteEnd
        } else {
            before = characterBeforeCursor()
        }
        guard let c = before else { return text }
        if c.isWhitespace || "([{“‘/-–".contains(c) { return text }
        return " " + text
    }

    /// Call right after pasting `text` into the app with this pid.
    static func didPaste(_ text: String, pid: pid_t?) {
        lastPasteAt = Date()
        lastPastePID = pid
        lastPasteEnd = text.last
        touchedSince = false
    }

    /// The character just before the cursor in the focused text field, or nil if there's none
    /// (start of the field) or Accessibility can't say.
    private static func characterBeforeCursor() -> Character? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let field = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(field, 0.2)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.location > 0 else { return nil }

        // Preferred: ask for just the one character.
        var one = CFRange(location: range.location - 1, length: 1)
        if let param = AXValueCreate(.cfRange, &one) {
            var strRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString,
                                                          param, &strRef) == .success,
               let s = strRef as? String, let c = s.last {
                return c
            }
        }
        // Fallback: read the whole value and index into it (Accessibility ranges are UTF-16 offsets).
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &valueRef) == .success,
           let s = valueRef as? String {
            let ns = s as NSString
            let i = range.location - 1
            if i < ns.length {
                let r = ns.rangeOfComposedCharacterSequence(at: i)
                return ns.substring(with: r).last
            }
        }
        return nil
    }
}
