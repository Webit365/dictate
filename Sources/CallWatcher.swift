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

/// A call app holding the microphone. `listenTo` is the bundle-ID prefix whose sound is checked for
/// voices before the call counts (nil: holding the mic is enough).
struct DetectedCall: Equatable {
    let name: String
    let listenTo: String?
}

/// Notices when a voice call starts and ends, by watching which apps are using the microphone
/// (macOS reports this per app). Used for "Auto-Start When a Call Begins".
///
/// A call app taking the mic isn't enough on its own: Slack opens the mic as soon as a huddle rings
/// and keeps it open until the huddle ends, even if you declined. So for native call apps the call
/// only counts once that app plays the other people's voices, which happens only after you join.
/// For browsers it needs a call window (Google Meet, Zoom or Teams on the web) instead.
/// The call has ended once no call app has used the mic for a while (muting in most call apps
/// keeps the mic open, and the grace period covers the ones that don't), or once the call app has
/// played no voices for several minutes (you left, but the app kept the mic).
final class CallWatcher {
    var onCallStarted: ((String) -> Void)?
    var onCallEnded: (() -> Void)?

    /// Seconds a call app must hold the mic before it counts as a call.
    var startAfter: TimeInterval = 4
    /// Seconds without any call app on the mic before the call counts as over.
    var endAfter: TimeInterval = 15
    /// Seconds of the other side's voice needed to know you've joined.
    var voiceNeeded: Double = 2
    /// Minutes of no voices from the call app before the call counts as over (you left).
    var silentEndAfter: TimeInterval = 5 * 60

    private(set) var inCall = false
    private var seenSince: Date?
    private var lastSeen = Date.distantPast
    private var timer: Timer?
    private var listener: VoiceListener?
    private var listenerStarted = Date.distantPast
    /// Where the current state comes from; replaceable for tests.
    var source: () -> DetectedCall? = { CallWatcher.currentCall() }
    var makeListener: (String) -> VoiceListener = { CallListener(bundlePrefix: $0) }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        inCall = false
        seenSince = nil
        dropListener()
    }

    private func dropListener() {
        listener?.stop()
        listener = nil
    }

    func tick(now: Date = Date()) {
        guard let call = source() else {
            seenSince = nil
            dropListener()
            if inCall, now.timeIntervalSince(lastSeen) >= endAfter {
                inCall = false
                onCallEnded?()
            }
            return
        }
        lastSeen = now
        if seenSince == nil { seenSince = now }

        if inCall {
            // In the call, but the app has gone quiet for minutes: you've left and it kept the mic.
            if let l = listener, !l.failed,
               now.timeIntervalSince(l.lastVoice ?? listenerStarted) >= silentEndAfter {
                inCall = false
                seenSince = now
                dropListener()
                onCallEnded?()
            }
            return
        }

        guard let since = seenSince, now.timeIntervalSince(since) >= startAfter else { return }
        if let prefix = call.listenTo {
            // Ringing or declined calls can hold the mic too: wait to hear the other side.
            if listener == nil {
                listener = makeListener(prefix)
                listenerStarted = now
            }
            guard let l = listener, l.failed || l.voiceSeconds >= voiceNeeded else { return }
        }
        inCall = true
        onCallStarted?(call.name)
    }

    // MARK: Which call is using the mic right now

    /// Bundle ID (or its prefix, so helper processes match too) → name shown in the notes.
    /// FaceTime and phone calls run through system services, so those can't be listened to and
    /// still start on the mic alone (they don't ring with the mic open).
    private static let unheard: Set<String> = ["FaceTime", "Phone call"]
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

    /// The call app using the mic, or nil if no call is going on.
    static func currentCall() -> DetectedCall? {
        var browserOnMic = false
        for p in micUsers() {
            if let hit = callApps.first(where: { p.bundleID.hasPrefix($0.0) }) {
                // FaceTime's background service also carries iPhone calls; the window tells them apart.
                if hit.1 == "FaceTime" {
                    return DetectedCall(name: CallApp.detect() == "FaceTime" ? "FaceTime" : "FaceTime / Phone", listenTo: nil)
                }
                return DetectedCall(name: hit.1, listenTo: unheard.contains(hit.1) ? nil : hit.0)
            }
            if browserPrefixes.contains(where: { p.bundleID.hasPrefix($0) }) { browserOnMic = true }
        }
        if browserOnMic, let web = CallApp.detect(), ["Google Meet", "Zoom", "Microsoft Teams", "Slack"].contains(web) {
            return DetectedCall(name: web, listenTo: nil)
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
