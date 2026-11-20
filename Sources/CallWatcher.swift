import AppKit
import CoreAudio
import Combine

/// The "auto-start call notes" switch, shared by the menu, the Notes tab and the widget.
final class AutoStartSetting: ObservableObject {
    static let shared = AutoStartSetting()
    /// Set by the app: starts or stops the call watcher.
    var onChange: ((Bool) -> Void)?

    @Published var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            Settings.shared.autoStartCalls = isOn
            onChange?(isOn)
        }
    }

    private init() { isOn = Settings.shared.autoStartCalls }
}

/// Notices when a voice call starts and ends, by watching which apps are using the microphone
/// (macOS reports this per app). Used for "Auto-Start When a Call Begins".
///
/// A call has started when a call app (Zoom, Teams, Slack huddle, FaceTime, a phone call through
/// the iPhone, WhatsApp…) keeps the mic open for a few seconds. For browsers it also needs a
/// call window (Google Meet, Zoom or Teams on the web), so a website using the mic doesn't count.
/// The call has ended once no call app has used the mic for a while (muting in most call apps
/// keeps the mic open, and the grace period covers the ones that don't).
final class CallWatcher {
    var onCallStarted: ((String) -> Void)?
    var onCallEnded: (() -> Void)?

    /// Seconds a call app must hold the mic before it counts as a call.
    var startAfter: TimeInterval = 4
    /// Seconds without any call app on the mic before the call counts as over.
    var endAfter: TimeInterval = 15

    private(set) var inCall = false
    private var seenSince: Date?
    private var lastSeen = Date.distantPast
    private var timer: Timer?
    /// Where the current state comes from; replaceable for tests.
    var source: () -> String? = { CallWatcher.currentCall() }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        inCall = false
        seenSince = nil
    }

    func tick(now: Date = Date()) {
        if let name = source() {
            lastSeen = now
            if seenSince == nil { seenSince = now }
            if !inCall, let since = seenSince, now.timeIntervalSince(since) >= startAfter {
                inCall = true
                onCallStarted?(name)
            }
        } else {
            seenSince = nil
            if inCall, now.timeIntervalSince(lastSeen) >= endAfter {
                inCall = false
                onCallEnded?()
            }
        }
    }

    // MARK: Which call is using the mic right now

    /// Bundle ID (or its prefix, so helper processes match too) → name shown in the notes.
    private static let callApps: [(String, String)] = [
        ("us.zoom.", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.apple.avconferenced", "FaceTime"),          // FaceTime and iPhone calls on the Mac
        ("com.apple.TelephonyUtilities", "Phone call"),
        ("com.apple.mobilephone", "Phone call"),
        ("com.cisco.webex", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"),
        ("com.facebook.archon", "Messenger"),
        ("org.whispersystems.signal-desktop", "Signal"),
        ("ru.keepcoder.Telegram", "Telegram"),
        ("com.goto.", "GoTo Meeting"),
        ("com.logmein.", "GoTo Meeting"),
        ("com.ringcentral.", "RingCentral"),
        ("com.skype.", "Skype"),
    ]

    private static let browserPrefixes = [
        "com.google.Chrome", "com.apple.Safari", "com.apple.WebKit", "company.thebrowser.", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "com.operasoftware.", "com.vivaldi.",
    ]

    /// Name of the call app using the mic, or nil if no call is going on.
    static func currentCall() -> String? {
        var browserOnMic = false
        for p in micUsers() {
            if let hit = callApps.first(where: { p.bundleID.hasPrefix($0.0) }) {
                // FaceTime's background service also carries iPhone calls; the window tells them apart.
                if hit.1 == "FaceTime" { return CallApp.detect() == "FaceTime" ? "FaceTime" : "FaceTime / Phone" }
                return hit.1
            }
            if browserPrefixes.contains(where: { p.bundleID.hasPrefix($0) }) { browserOnMic = true }
        }
        if browserOnMic, let web = CallApp.detect(), ["Google Meet", "Zoom", "Microsoft Teams", "Slack"].contains(web) {
            return web
        }
        return nil
    }

    struct MicUser { let pid: pid_t; let bundleID: String }

    /// Apps (other than Wisp) whose microphone input is running right now.
    static func micUsers() -> [MicUser] {
        let me = getpid()
        return processObjects().compactMap { obj in
            guard uint32(obj, kAudioProcessPropertyIsRunningInput) != 0 else { return nil }
            let pid = pid_t(bitPattern: uint32(obj, kAudioProcessPropertyPID))
            guard pid != me else { return nil }
            return MicUser(pid: pid, bundleID: bundleID(obj)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")
        }
    }

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var addr = address(sel)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : 0
    }

    private static func bundleID(_ obj: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr, let s = v?.takeRetainedValue() else {
            return nil
        }
        let id = s as String
        return id.isEmpty ? nil : id
    }
}
