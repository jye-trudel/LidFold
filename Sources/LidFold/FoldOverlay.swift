import AppKit
import Metal
import QuartzCore

/// One borderless, transparent, click-through window per covered screen.
///
/// Window level: `.screenSaver` (CGWindowLevel 1000). It must sit above the menu bar (24),
/// Dock (20), status items (25) and pop-up menus (101) so the *whole* desktop folds, but stay
/// below the system shielding window used by the lock screen / loginwindow, so we can never
/// obscure the password prompt. `.canJoinAllSpaces` + `.fullScreenAuxiliary` put it on every
/// Space, including over full-screen apps.
///
/// Two renderers:
///  • Duo (default, needs Screen Recording): one ScreenCaptureKit still per display, taken when
///    a close starts, smeared vertically on the GPU (DuoRenderer). Kept through sleep for the
///    wake un-blur; freed when the lid settles open.
///  • Frosted (fallback, no permission): NSVisualEffectView behind-window blur + gradients.
/// Everything is driven straight from progress; implicit animations are disabled.
@MainActor
final class FoldOverlay {
    private var windows: [CGDirectDisplayID: FoldWindow] = [:]
    private var current: Double = 0
    private var renderer: DuoRenderer?
    private var capturing: Set<CGDirectDisplayID> = []
    /// Lock-screen covers: frosted windows *above* the lock screen (see addLockCovers).
    private var covers: [CGDirectDisplayID: FoldWindow] = [:]
    private var lockMode = false
    private var lockCard = false        // lock mode with the captured-lock-screen glass card
    private var handingOver = false
    private var generation = 0

    func apply(_ p: Double) {
        current = p
        if p <= 0.0005, lockCard, !handingOver {
            handOverToLockScreen()
            return
        }
        if handingOver { return }
        if p <= 0.0005 {
            // While the lid moves, keep windows on screen but transparent (no re-order hitch);
            // they're removed entirely when the lid settles (purgeIfHidden).
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for w in windows.values where w.isVisible { w.render(0) }
            CATransaction.commit()
            return
        }
        if windows.isEmpty { build() }
        captureMissingSnapshots()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for w in windows.values { w.render(p) }
        CATransaction.commit()
        for w in windows.values where !w.isVisible { w.orderFrontRegardless() }
    }

    /// Before sleep: make sure the opaque frame is actually on the glass before the display goes off.
    func flush() {
        for w in windows.values { w.flushFrame() }
        for w in covers.values { w.flushFrame() }
        CATransaction.flush()
    }

    /// Lid started moving: build (transparent) windows now so the first frame doesn't hitch,
    /// and if it's closing, grab the one snapshot per display the smear needs.
    func prewarm(closing: Bool) {
        if windows.isEmpty {
            build()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            // Lock cards are already shown and moved into the above-lock-screen space; ordering them
            // front again could put them back in the normal space.
            for w in windows.values { w.render(current); if !w.isVisible { w.orderFrontRegardless() } }
            CATransaction.commit()
        }
        if closing { captureMissingSnapshots() }
    }

    // MARK: lock screen

    /// Before sleep: a black, click-through cover above the lock screen (which appears on sleep
    /// when a password is required), so the panel wakes covered even if it wakes locked.
    func addLockCovers() {
        // Public window levels can't go above loginwindow; without SkyLight there's no point.
        guard covers.isEmpty, Self.hasBuiltInScreen, SkyLight.isAvailable else { return }
        let targets = Settings.allScreens ? NSScreen.screens : NSScreen.screens.filter(\.isBuiltIn)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for s in targets {
            let w = OverlayWindow(screen: s, aboveLockScreen: true)
            w.render(1)
            // Order in first, then move: a window that isn't on screen yet has nothing to move, and
            // ordering in afterwards would place it in the current (normal) space.
            w.orderFrontRegardless()
            guard SkyLight.moveAboveLockScreen(w) else { w.orderOut(nil); w.close(); continue }
            covers[s.displayID] = w
        }
        CATransaction.commit()
    }

    /// True while anything is shown above the lock screen (covers, or the lock-mode opening).
    var hasLockSurfaces: Bool { !covers.isEmpty || lockMode }

    /// Failsafe: take everything down from above the lock screen, immediately.
    func removeLockSurfaces() {
        removeLockCovers()
        if lockMode { current = 0; tearDown() }
    }

    func removeLockCovers() {
        for w in covers.values { w.orderOut(nil); w.releaseContents(); w.close() }
        covers.removeAll()
    }

    /// Woke locked: drop the glass-card windows (their snapshot is the desktop) and let the covers
    /// above the lock screen play the frosted opening. They blur only what's beneath them live.
    func enterLockMode() {
        tearDown()
        lockMode = true
        windows = covers
        covers.removeAll()
        if windows.isEmpty { build() }
    }

    /// Frees the desktop snapshot(s) right away (at sleep / when the Mac locks). The windows stay,
    /// fully dissolved (black), so nothing is uncovered.
    func dropDesktopSnapshots() {
        guard !lockMode else { return }
        renderer?.finish()
        for w in windows.values { (w as? DuoWindow)?.snapshot = nil }
        generation += 1
        capturing.removeAll()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for w in windows.values { w.render(current) }
        CATransaction.commit()
    }

    /// Woke locked: capture the LIVE LOCK SCREEN (our black cover excluded) and turn it into the
    /// glass card above the lock screen, which then plays the reverse of the close. The capture is
    /// only taken while the session reports locked, so it can only contain the lock screen.
    /// `completion(true)` once the card has replaced the black cover; `false` if capture failed or
    /// came back black (caller falls back to the frosted live blur).
    func beginLockCard(completion: @escaping (Bool) -> Void) {
        tearDown()                                  // desktop windows/snapshot gone
        guard Settings.style == .duo, ScreenSnapshot.hasPermission, !covers.isEmpty else { completion(false); return }
        lockMode = true
        if renderer == nil { renderer = DuoRenderer.make() }
        guard let renderer else { completion(false); return }
        let gen = generation
        let targets = covers.keys.compactMap { id in NSScreen.screens.first { $0.displayID == id } }
        var pending = targets.count
        var ok = true
        for screen in targets {
            let id = screen.displayID
            // Native Retina resolution: the card ends full-screen and sharp and cross-fades into the
            // live lock screen, so it must be exactly as crisp (a half-res card read as a jump).
            let scale = Double(screen.backingScaleFactor)
            let size = CGSize(width: (screen.frame.width * scale).rounded(), height: (screen.frame.height * scale).rounded())
            let t0 = CACurrentMediaTime()
            Task { @MainActor [weak self] in
                let locked = AppDelegate.screenIsLocked
                let image = locked ? await ScreenSnapshot.capture(displayID: id, size: size, native: true) : nil
                let ms = (CACurrentMediaTime() - t0) * 1000
                guard let self, gen == self.generation else { return }
                let luma = image.map(Self.meanLuma) ?? 0
                debugLog(String(format: "lock capture: %@ in %.0f ms, mean luma %.3f, still locked %@",
                                image == nil ? "FAILED" : "ok", ms, luma, AppDelegate.screenIsLocked ? "yes" : "no"))
                if let image, ProcessInfo.processInfo.environment["LIDFOLD_DEBUG"] != nil { Self.saveDebug(image) }
                if let image, luma > 0.01, AppDelegate.screenIsLocked {
                    let w = DuoWindow(screen: screen, renderer: renderer, scale: scale)
                    let snap = renderer.makeSnapshot(image, size: size)
                    snap?.pixelsPerPoint = scale
                    w.snapshot = snap
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    w.render(self.current)              // fully dissolved: black, like the cover
                    CATransaction.commit()
                    w.orderFrontRegardless()
                    if SkyLight.moveAboveLockScreen(w) { self.windows[id] = w } else { w.orderOut(nil); w.close(); ok = false }
                } else {
                    ok = false
                }
                pending -= 1
                if pending == 0 {
                    if ok && !self.windows.isEmpty {
                        self.lockCard = true
                        self.removeLockCovers()         // the black card now covers instead
                        completion(true)
                    } else {
                        for w in self.windows.values { w.orderOut(nil); w.releaseContents(); w.close() }
                        self.windows.removeAll()
                        self.lockMode = false
                        completion(false)
                    }
                }
            }
        }
        if targets.isEmpty { lockMode = false; completion(false) }
    }

    /// End of the opening on the lock screen: the card is full-screen and sharp; cross-fade it into
    /// the live lock screen over ~100 ms, then remove everything.
    private func handOverToLockScreen() {
        handingOver = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for w in windows.values { w.render(0.0006) }    // identity transform, unblurred, opaque
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            for w in windows.values { w.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.handingOver else { return }
                self.current = 0
                self.tearDown()
            }
        })
    }

    private static func meanLuma(_ img: CGImage) -> Double {
        let w = 32, h = 20
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0
        for i in stride(from: 0, to: px.count, by: 4) { sum += Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) }
        return Double(sum) / Double(w * h * 3 * 255)
    }

    private static func saveDebug(_ img: CGImage) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lidfold-lock-capture.png")
        if let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? data.write(to: url); debugLog("lock capture saved: \(url.path)")
        }
    }

    /// After wake: make sure windows exist (still fully dissolved) and have a snapshot to open with.
    func ensureSnapshots() {
        if windows.isEmpty && current > 0.0005 { apply(current) }
        captureMissingSnapshots()
    }

    /// True when every Duo window has its snapshot (or there are none, e.g. frosted fallback).
    var snapshotsReady: Bool {
        windows.values.allSatisfy { ($0 as? DuoWindow)?.snapshot != nil || !($0 is DuoWindow) }
    }

    /// Called when the lid settles: free windows, snapshots and GPU objects if nothing is showing.
    func purgeIfHidden() {
        if current <= 0.0005 && !handingOver { tearDown() }
    }

    func screensChanged() {
        // Never rebuild anything above the lock screen on a display change: just uncover it.
        if hasLockSurfaces { removeLockSurfaces(); return }
        tearDown()
        if current > 0.0005 { apply(current) }
    }

    /// The built-in panel is the one that folds. With the lid closed and external displays in
    /// use (clamshell), it isn't in NSScreen.screens — then we cover nothing, so external
    /// monitors never get stuck dark.
    static var hasBuiltInScreen: Bool { NSScreen.screens.contains { $0.isBuiltIn } }

    /// Whether the directional (Duo) effect is in use right now.
    static var duoAvailable: Bool { Settings.style == .duo && ScreenSnapshot.hasPermission }

    private func build() {
        guard Self.hasBuiltInScreen else { return }
        let targets = Settings.allScreens ? NSScreen.screens : NSScreen.screens.filter(\.isBuiltIn)
        // Closing while the lock screen is up: the normal windows would sit *below* it, unseen.
        // Build the glass card above the lock screen instead; it captures the lock screen itself.
        if !lockMode, AppDelegate.screenIsLocked, SkyLight.isAvailable, Self.duoAvailable {
            if renderer == nil { renderer = DuoRenderer.make() }
            if let r = renderer {
                lockMode = true
                lockCard = true
                CATransaction.begin(); CATransaction.setDisableActions(true)
                for s in targets {
                    let w = DuoWindow(lockCardOn: s, renderer: r)
                    w.render(current)
                    w.orderFrontRegardless()
                    if SkyLight.moveAboveLockScreen(w) { windows[s.displayID] = w } else { w.orderOut(nil); w.close() }
                }
                CATransaction.commit()
                debugLog("build windows: lock card (closing from the lock screen), \(windows.count)")
                if !windows.isEmpty { return }
                lockMode = false; lockCard = false
            }
        }
        if lockMode {
            for s in targets {
                let w = OverlayWindow(screen: s, aboveLockScreen: true)
                w.render(current)
                w.orderFrontRegardless()
                if SkyLight.moveAboveLockScreen(w) { windows[s.displayID] = w } else { w.orderOut(nil); w.close() }
            }
            return
        }
        if Self.duoAvailable, renderer == nil { renderer = DuoRenderer.make() }
        debugLog("build windows: \(Self.duoAvailable && renderer != nil ? "duo" : "frosted")")
        for s in targets {
            if Self.duoAvailable, let r = renderer {
                windows[s.displayID] = DuoWindow(screen: s, renderer: r)
            } else {
                windows[s.displayID] = OverlayWindow(screen: s)
            }
        }
    }

    private func captureMissingSnapshots() {
        guard let renderer else { return }
        let gen = generation
        for (id, w) in windows {
            guard let duo = w as? DuoWindow, duo.snapshot == nil, !capturing.contains(id) else { continue }
            // Above the lock screen only lock cards may get an image, and only while locked
            // (so it can only be the lock screen). Desktop windows never capture in lock mode.
            if lockMode && !duo.isLockCard { continue }
            if duo.isLockCard && !AppDelegate.screenIsLocked { continue }
            capturing.insert(id)
            let size = duo.pixelSize
            let native = duo.isLockCard
            let t0 = CACurrentMediaTime()
            Task { @MainActor [weak self] in
                let image = await ScreenSnapshot.capture(displayID: id, size: size, native: native)
                guard let self, gen == self.generation else { return }
                self.capturing.remove(id)
                guard let image, let win = self.windows[id] as? DuoWindow else {
                    debugLog("capture failed for display \(id)"); return
                }
                if win.isLockCard && !AppDelegate.screenIsLocked { return }   // unlocked meanwhile: discard
                let t1 = CACurrentMediaTime()
                let snap = renderer.makeSnapshot(image, size: size)
                if native { snap?.pixelsPerPoint = size.width / win.frame.width }
                win.snapshot = snap
                debugLog(String(format: "snapshot %dx%d: capture %.0f ms, upload+pyramid %.1f ms",
                                image.width, image.height, (t1 - t0) * 1000, (CACurrentMediaTime() - t1) * 1000))
                if self.current > 0.0005 { win.render(self.current) }
            }
        }
    }

    private func tearDown() {
        lockMode = false
        lockCard = false
        handingOver = false
        FrameStats.report()
        renderer?.finish()    // GPU must be done with snapshots/drawables before they're freed
        for w in windows.values {
            w.orderOut(nil)
            w.releaseContents()
            w.close()
        }
        windows.removeAll()   // windows, backing stores and snapshots are freed while idle
        renderer = nil
        capturing.removeAll()
        generation += 1
    }
}

/// `LIDFOLD_DEBUG=1` prints timings to stderr.
func debugLog(_ s: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["LIDFOLD_DEBUG"] != nil else { return }
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    FileHandle.standardError.write("\(f.string(from: Date())) [\(info.phys_footprint >> 20) MB] \(s())\n".data(using: .utf8)!)
}

/// Debug-only frame timing (printed with LIDFOLD_DEBUG when a fold settles).
enum FrameStats {
    nonisolated(unsafe) static var times: [Double] = []
    static func add(_ t: Double) { if ProcessInfo.processInfo.environment["LIDFOLD_DEBUG"] != nil { times.append(t) } }
    static func report() {
        guard !times.isEmpty else { return }
        let s = times.sorted()
        debugLog(String(format: "frames %d: render+present median %.2f ms, p95 %.2f ms, max %.2f ms, over 8.3 ms: %d",
                        s.count, s[s.count / 2] * 1000, s[Int(Double(s.count) * 0.95)] * 1000, s.last! * 1000, s.filter { $0 > 0.0083 }.count))
        times.removeAll()
    }
}

/// Common window setup for both renderers.
@MainActor
class FoldWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    func render(_ p: Double) {}
    func flushFrame() { displayIfNeeded() }
    /// Drop GPU/CA resources before closing (layers can otherwise outlive the window).
    func releaseContents() { contentView = nil }
}

/// Directional-blur window: a CAMetalLayer the DuoRenderer draws into, only when progress changes.
@MainActor
final class DuoWindow: FoldWindow {
    private let renderer: DuoRenderer
    private let metal = CAMetalLayer()
    private let card = CALayer()        // container: everything on it tilts as one pane
    private var host: CALayer!          // card's parent; its background is the black backdrop
    private let size: CGSize
    let pixelSize: CGSize
    private var lastProgress: Double = 0
    var snapshot: DuoRenderer.Snapshot? {
        didSet {
            if let cs = snapshot?.colorSpace { metal.colorspace = cs }
            snapshotTime = CACurrentMediaTime()
        }
    }
    private var snapshotTime: CFTimeInterval = 0

    /// A lock card lives above the lock screen and may only ever show a lock-screen capture.
    private(set) var isLockCard = false

    convenience init(lockCardOn screen: NSScreen, renderer: DuoRenderer) {
        self.init(screen: screen, renderer: renderer, scale: Double(screen.backingScaleFactor))
        isLockCard = true
    }

    init(screen: NSScreen, renderer: DuoRenderer, scale overrideScale: Double? = nil) {
        self.renderer = renderer
        let scale = overrideScale ?? Settings.snapshotScale
        pixelSize = CGSize(width: (screen.frame.width * scale).rounded(), height: (screen.frame.height * scale).rounded())
        size = screen.frame.size
        super.init(screen: screen)
        metal.device = renderer.device
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = false
        metal.framebufferOnly = false   // the compute shader writes the drawable directly
        metal.drawableSize = pixelSize
        metal.contentsScale = screen.backingScaleFactor   // match the window (a mismatch forces an extra composite surface)
        metal.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        metal.maximumDrawableCount = 3   // 2 makes nextDrawable block with presentsWithTransaction
        metal.allowsNextDrawableTimeout = true
        metal.presentsWithTransaction = true
        metal.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        host = view.layer!
        Card.configure(container: card, host: host, size: size)
        metal.frame = card.bounds
        card.addSublayer(metal)
        host.addSublayer(card)
        contentView = view
    }

    override func releaseContents() {
        snapshot = nil
        // System frame pacing can keep a CAMetalLayer referenced after its window closes; shrink
        // the drawables so whatever lingers holds 1×1 surfaces instead of ~17 MB.
        metal.drawableSize = CGSize(width: 1, height: 1)
        metal.presentsWithTransaction = false
        for _ in 0..<3 {                     // cycle the whole pool (maximumDrawableCount) so the full-size drawables are dropped
            if let d = metal.nextDrawable() { renderer.render(progress: 0, snapshot: nil, to: d.texture, present: d, wait: true) }
        }
        metal.contents = nil                 // the last presented frame lives on as layer contents
        metal.removeFromSuperlayer()
        super.releaseContents()
    }
    override func render(_ p: Double) {
        lastProgress = p
        let t0 = CACurrentMediaTime()
        defer { FrameStats.add(CACurrentMediaTime() - t0) }
        // The lean-back needs the captured frame; until it exists the card stays upright, and when
        // it arrives mid-close the tilt eases in over 150 ms instead of popping.
        var cardP = 0.0
        if snapshot != nil {
            let k = min(1, (CACurrentMediaTime() - snapshotTime) / 0.15)
            cardP = p * k * k * (3 - 2 * k)
        }
        Card.apply(cardP, container: card, host: host, size: size)
        guard let drawable = metal.nextDrawable() else { return }
        renderer.render(progress: p, snapshot: snapshot, to: drawable.texture, present: drawable, inTransaction: true)
    }

    override func flushFrame() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        render(lastProgress)
        CATransaction.commit()
        renderer.finish()
    }
}

@MainActor
final class OverlayWindow: FoldWindow {
    private let blur = NSVisualEffectView()
    private let style: Settings.Style
    private let size: CGSize

    // classic
    private let gradient = CAGradientLayer()
    // eclipse
    private let eclipse = CAGradientLayer()
    private let corona = CAGradientLayer()
    // both: final guarantee of pure black at p = 1
    private let solid = CALayer()

    private static let black = CGColor(gray: 0, alpha: 1)
    private static let clear = CGColor(gray: 0, alpha: 0)

    convenience override init(screen: NSScreen) { self.init(screen: screen, aboveLockScreen: false) }

    /// `aboveLockScreen`: sits at the shielding level and may show before login, so it can play
    /// the opening over the lock screen. Always the classic live-blur style there: it captures
    /// nothing and only ever blurs what's beneath it (the lock screen), never the desktop.
    init(screen: NSScreen, aboveLockScreen: Bool) {
        style = aboveLockScreen ? .classic : (Settings.style == .eclipse ? .eclipse : .classic)
        size = screen.frame.size
        super.init(screen: screen)
        if aboveLockScreen {
            level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            canBecomeVisibleWithoutLogin = true
        }

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]

        blur.frame = root.bounds
        blur.autoresizingMask = [.width, .height]
        blur.blendingMode = .behindWindow
        blur.material = .fullScreenUI
        blur.state = .active                       // stay blurred even though we're never key
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.alphaValue = 0
        root.addSubview(blur)

        // Layer-hosting view for the darkening (pure Core Animation, no drawRect).
        let dimHost = CALayer()
        dimHost.frame = root.bounds
        switch style {
        case .classic:
            gradient.frame = root.bounds
            gradient.startPoint = CGPoint(x: 0.5, y: 0)  // macOS layer space: y = 0 is the bottom (hinge)
            gradient.colors = [Self.black, Self.black, Self.clear]
            gradient.locations = [0, 0.35, 1]
            dimHost.addSublayer(gradient)
        case .eclipse, .duo:
            // Half eclipse: a radial gradient centred on the middle of the bottom edge (the
            // hinge), so only the upper half-disc shows: a dome of light whose diameter lies
            // along the bottom of the screen. Location 0 = centre, 1 = radius R (set per frame).
            for g in [eclipse, corona] {
                g.frame = root.bounds
                g.type = .radial
                g.startPoint = CGPoint(x: 0.5, y: 0)   // macOS layer space: y = 0 is the bottom
            }
            eclipse.colors = [Self.clear, Self.clear, CGColor(gray: 0, alpha: 0.55), Self.black]
            eclipse.locations = [0, 0.55, 0.85, 1]
            // Corona: a faint light rim riding just inside the shadow's edge.
            let glow = CGColor(red: 1, green: 0.97, blue: 0.92, alpha: 1)
            corona.colors = [Self.clear, Self.clear, glow.copy(alpha: 0.9)!, Self.clear, Self.clear]
            corona.locations = [0, 0.47, 0.56, 0.68, 1]
            corona.opacity = 0
            dimHost.addSublayer(eclipse)
            dimHost.addSublayer(corona)
        }
        solid.frame = root.bounds
        solid.backgroundColor = Self.black
        solid.opacity = 0
        dimHost.addSublayer(solid)
        let dim = NSView(frame: root.bounds)
        dim.layer = dimHost
        dim.wantsLayer = true
        dim.autoresizingMask = [.width, .height]
        root.addSubview(dim)

        contentView = root
    }

    override func render(_ p: Double) {
        switch style {
        case .classic:
            blur.alphaValue = smoothstep(0, 0.45, p)          // focus goes first
            // Shadow rising from the hinge: its top edge climbs from 0 to ~1.4 screen heights.
            let reach = max(0.001, 0.15 + 1.25 * p)
            gradient.endPoint = CGPoint(x: 0.5, y: reach)
            gradient.opacity = Float(0.92 * smoothstep(0, 0.8, p))
            solid.opacity = Float(smoothstep(0.6, 1, p))      // final dissolve to black

        case .eclipse, .duo:
            blur.alphaValue = smoothstep(0, 0.4, p)
            // Dome radius: starts with the clear core reaching the top corners, sinks into the hinge.
            let reach = hypot(size.width / 2, size.height)    // bottom-centre → top corner
            let r0 = reach / 0.55 * 1.04
            let q = 0.5 - 0.5 * cos(.pi * p)                  // ease in-out
            let r = max(0.5, r0 * (1 - q))
            let end = CGPoint(x: 0.5 + r / size.width, y: r / size.height)  // circular, not elliptical
            eclipse.endPoint = end
            corona.endPoint = end
            // Rim glows mid-close and fades as the circle gets small.
            corona.opacity = Float(Settings.corona * pow(sin(.pi * min(1, p / 0.92)), 1.5))
            solid.opacity = Float(smoothstep(0.9, 1, p))
        }
    }
}

private func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}
