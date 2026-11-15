import AppKit
import CoreGraphics

/// Works out which call app a recording came from (Zoom, Slack huddle, Teams, Google Meet…),
/// so the notes don't just name whatever app happened to be in front.
enum CallApp {
    /// Bundle ID → friendly name, for native call apps.
    private static let native: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.hnc.Discord": "Discord",
        "com.goto.gotomeeting": "GoTo Meeting",
        "com.ringcentral.glip": "RingCentral",
    ]

    private static let browsers: Set<String> = [
        "Google Chrome", "Safari", "Arc", "Microsoft Edge", "Firefox", "Brave Browser", "Opera", "Vivaldi", "Dia",
    ]

    /// The call app in use right now, or nil if no call is detected.
    static func detect() -> String? {
        let windows = onScreenWindows()

        // 1. A window that looks like a live call.
        for (owner, title) in windows {
            let t = title.lowercased()
            switch owner {
            case "zoom.us" where t.contains("meeting") || t.contains("webinar"): return "Zoom"
            case "Slack" where t.contains("huddle"): return "Slack"
            case "Microsoft Teams" where t.contains("meeting") || t.contains("call"): return "Microsoft Teams"
            case "FaceTime" where !t.isEmpty: return "FaceTime"
            case "Webex" where t.contains("meeting"): return "Webex"
            default: break
            }
            if browsers.contains(owner) {
                if t.hasPrefix("meet -") || t.contains("google meet") { return "Google Meet" }
                if t.contains("zoom meeting") || t.contains("app.zoom.us") { return "Zoom" }
                if t.contains("microsoft teams") && (t.contains("meeting") || t.contains("call")) { return "Microsoft Teams" }
                if t.contains("huddle") { return "Slack" }
            }
        }

        // 2. A call app that's in front.
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, let name = native[id] { return name }
        return nil
    }

    /// (app name, window title) for on-screen windows. Titles need Screen & System Audio Recording
    /// permission, which call notes already require.
    private static func onScreenWindows() -> [(String, String)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return info.compactMap { w in
            guard let owner = w[kCGWindowOwnerName as String] as? String else { return nil }
            return (owner, w[kCGWindowName as String] as? String ?? "")
        }
    }
}
