import AppKit
import SwiftUI

/// State shown by the floating head widget.
final class HeadModel: ObservableObject {
    enum Mode { case idle, listening, thinking }
    @Published var mode: Mode = .idle
    @Published var level: CGFloat = 0          // 0…1 microphone loudness while listening
    @Published var callRecording = false
    @Published var callBusy: String?           // "Transcribing…", "Writing notes…"
    @Published var callSeconds = 0
    @Published var setup: String?             // first-launch model download progress
    var onToggleNotes: (() -> Void)?
    var onHide: (() -> Void)?
    var onOpenStyles: (() -> Void)?
    var onOpenNotes: (() -> Void)?
}

/// The Webit365 logo (white W on a red circle, from webit365.com/favicon.svg), animated:
/// the W's points bounce with your voice while dictating, and a ring spins while it's thinking.
struct LogoW: View {
    let mode: HeadModel.Mode
    let level: CGFloat

    static let brandRed = Color(red: 0xE1 / 255.0, green: 0x1D / 255.0, blue: 0x3C / 255.0)
    /// The W's corner points in the logo's 100×100 artwork.
    static let points: [CGPoint] = [CGPoint(x: 26, y: 31), CGPoint(x: 38, y: 71), CGPoint(x: 50, y: 47),
                                    CGPoint(x: 62, y: 71), CGPoint(x: 74, y: 31)]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t: Double = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                LogoW.draw(in: &ctx, size: size, mode: mode, level: level, t: t)
            }
            .frame(width: 36, height: 36)
            .padding(.vertical, 6)
        }
    }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, mode: HeadModel.Mode, level: CGFloat, t: Double) {
        let listening: Bool = mode == .listening
        let thinking: Bool = mode == .thinking
        let side: CGFloat = min(size.width, size.height)
        let pulse: CGFloat = listening ? 0.90 + 0.10 * level : 0.90
        let diameter: CGFloat = side * pulse
        let unit: CGFloat = diameter / 100
        let origin = CGPoint(x: (size.width - diameter) / 2, y: (size.height - diameter) / 2)
        let circle = Path(ellipseIn: CGRect(origin: origin, size: CGSize(width: diameter, height: diameter)))

        // Glow while listening.
        if listening {
            var glow = ctx
            glow.addFilter(.blur(radius: 2 + 3 * level))
            glow.fill(circle, with: .color(brandRed.opacity(0.55 + 0.4 * Double(level))))
        }
        ctx.fill(circle, with: .color(brandRed))

        // The W, with each corner bouncing on its own beat while you talk.
        let amp: Double = listening ? 3 + 11 * Double(level) : 0
        var w = Path()
        for (i, p) in points.enumerated() {
            let dy: Double = amp * sin(t * 14 + Double(i) * 1.15)
            let x: CGFloat = origin.x + p.x * unit
            let y: CGFloat = origin.y + (p.y + CGFloat(dy)) * unit
            if i == 0 { w.move(to: CGPoint(x: x, y: y)) } else { w.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(w, with: .color(.white),
                   style: StrokeStyle(lineWidth: 9 * unit, lineCap: .round, lineJoin: .round))

        // Spinning ring while cleaning up.
        if thinking {
            let inset: CGFloat = 1.5
            let ringRect = CGRect(x: origin.x - inset, y: origin.y - inset,
                                  width: diameter + 2 * inset, height: diameter + 2 * inset)
            let start: Double = (t * 360).truncatingRemainder(dividingBy: 360)
            var arc = Path()
            arc.addArc(center: CGPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRect.width / 2,
                       startAngle: .degrees(start), endAngle: .degrees(start + 100), clockwise: false)
            ctx.stroke(arc, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}

struct HeadWidget: View {
    @ObservedObject var model: HeadModel
    @ObservedObject var auto = AutoStartSetting.shared

    var body: some View {
        HStack(spacing: 8) {
            LogoW(mode: model.mode, level: model.level)
            notesButton
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color(white: 0.11).opacity(0.92))
                .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .contextMenu {
            Button("Style…") { model.onOpenStyles?() }
            Button("All Call Notes…") { model.onOpenNotes?() }
            Toggle("Auto-Start Notes on Calls", isOn: $auto.isOn)
            Divider()
            Button("Hide Floating Head") { model.onHide?() }
        }
        .help(helpText)
    }

    private var notesButton: some View {
        Button(action: { model.onToggleNotes?() }) {
            HStack(spacing: 5) {
                if model.callBusy != nil || model.setup != nil {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 9, height: 9)
                } else {
                    Circle()
                        .fill(model.callRecording ? Color.red
                              : auto.isOn ? Color(red: 0.2, green: 0.85, blue: 0.4) : Color.white.opacity(0.55))
                        .frame(width: 8, height: 8)
                        .opacity(model.callRecording && model.callSeconds % 2 == 1 ? 0.35 : 1)
                }
                Text(notesLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(model.callRecording ? Color.red.opacity(0.28) : Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .disabled(model.callBusy != nil || model.setup != nil)
    }

    private var notesLabel: String {
        if let setup = model.setup { return setup }
        if model.callBusy != nil { return "Writing notes" }
        if model.callRecording {
            let s = model.callSeconds
            return String(format: "Stop %d:%02d", s / 60, s % 60)
        }
        return "Notes"
    }

    private var helpText: String {
        if model.callRecording { return "Recording call notes. Click Stop to write the notes." }
        if let busy = model.callBusy { return busy }
        let base = "Hold \(Settings.shared.hotkey.title) to dictate. Click the W for Style. Click Notes to record a call."
        return auto.isOn ? base + " Auto-start is on (green dot): calls start notes by themselves. Right-click to turn it off."
                         : base + " Right-click to turn on auto-start for calls."
    }
}

/// Lets clicks land on the widget without first activating Wisp (so focus stays in your app).
/// The W logo on the left is handled here: a click opens Style, a drag moves the widget.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onLogoClick: (() -> Void)?
    /// Leading padding + logo width, in points.
    var logoWidth: CGFloat = 52

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window, convert(event.locationInWindow, from: nil).x <= logoWidth else {
            super.mouseDown(with: event)
            return
        }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var moved = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x, dy = now.y - startMouse.y
            if abs(dx) > 3 || abs(dy) > 3 { moved = true }
            if moved { window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)) }
        }
        if !moved { onLogoClick?() }
    }
}

/// A floating, draggable panel that never takes keyboard focus, so pasting still goes
/// to the app you were typing in.
final class FloatingPanel: NSPanel {
    init(model: HeadModel) {
        let host = FirstMouseHostingView(rootView: HeadWidget(model: model))
        host.onLogoClick = { [weak model] in model?.onOpenStyles?() }
        let size = NSSize(width: 150, height: 48)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host
        setFrameOrigin(Self.savedOrigin(for: size))
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            guard let o = self?.frame.origin else { return }
            UserDefaults.standard.set(["x": o.x, "y": o.y], forKey: "headOrigin")
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private static func savedOrigin(for size: NSSize) -> NSPoint {
        if let d = UserDefaults.standard.dictionary(forKey: "headOrigin") as? [String: CGFloat],
           let x = d["x"], let y = d["y"] {
            let p = NSPoint(x: x, y: y)
            // Only reuse it if it's still on a connected screen.
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(p) }) { return p }
        }
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 24)   // bottom center, above the Dock
    }
}
