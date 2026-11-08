import AppKit
import QuartzCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let duoItem = NSMenuItem(title: "Glass Card Effect", action: #selector(toggleDuo), keyEquivalent: "")

    private let sensor = LidSensor()
    private let overlay = FoldOverlay()
    private lazy var tracker = LidTracker(sensor: sensor)
    private var hasSensor = false

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.registerDefaults()

        // `LidFold --preview 0.5` shows a fixed fold state for 3 s, then quits (for tuning the look).
        let args = CommandLine.arguments
        // `LidFold --render-test <out-dir>` renders the Duo shader offscreen to PNGs (no window, no capture).
        if let i = args.firstIndex(of: "--render-test"), i + 1 < args.count {
            RenderTest.run(outDir: args[i + 1]); exit(0)
        }
        // `LidFold --linktest`: how long until a fresh display link delivers its first callbacks.
        if args.contains("--linktest") { LinkTest.shared.run(); return }
        // LF_FORCE_LOCK=1 (debug): treat the session as locked, to exercise the lock-screen paths.
        if ProcessInfo.processInfo.environment["LF_FORCE_LOCK"] != nil { Self.debugForceLocked = true }
        // `LidFold --demo` plays a full close → hold → open (≈4.5 s), then quits.
        if args.contains("--demo") { runDemo(); return }
        if let i = args.firstIndex(of: "--preview"), i + 1 < args.count, let p = Double(args[i + 1]) {
            overlay.apply(min(1, max(0, p)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
            return
        }
        hasSensor = sensor.open()
        buildMenu()

        tracker.onProgress = { [weak self] p in self?.overlay.apply(p) }
        tracker.onSettled = { [weak self] in self?.overlay.purgeIfHidden() }
        tracker.onActive = { [weak self] closing in self?.overlay.prewarm(closing: closing) }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        applyEnabled()
        if Settings.style == .duo { ScreenSnapshot.requestPermissionIfNeeded() }
        // Debug hook: `notifyutil`-style trigger to time the start-of-close path after real idle.
        if ProcessInfo.processInfo.environment["LIDFOLD_DEBUG"] != nil {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.lidfold.debugPrewarm"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tracker.debugBegin()
                }
            }
            // Debug: lock-card hand-off test (simulated lock): hold the final card frame 2 s, then hand over.
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.lidfold.debugHandover"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Self.debugForceLocked = true
                    self.overlay.apply(1); self.overlay.addLockCovers()
                    self.overlay.beginLockCard { ok in
                        debugLog("debug handover: card ready=\(ok)")
                        self.overlay.apply(0.0006)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated {
                            debugLog("debug handover: handing over"); self.overlay.apply(0)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.debugForceLocked = false }
                        } }
                    }
                }
            }
            // Debug: put a half-frosted cover in the above-lock-screen space for 3 s (for real-lock tests).
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.lidfold.debugCoverTest"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    debugLog("debug: cover test, locked=\(Self.screenIsLocked) skylight=\(SkyLight.isAvailable)")
                    self.overlay.addLockCovers()
                    self.overlay.enterLockMode()
                    self.overlay.apply(0.5)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated {
                        self.overlay.removeLockSurfaces(); debugLog("debug: cover test done") } }
                }
            }
            // Debug: same, but waking into a (simulated) lock screen.
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.lidfold.debugLockedWake"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Self.debugForceLocked = true
                    debugLog("debug: willSleep (locked)"); self?.willSleep()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated { self?.systemDidWake() } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { debugLog("debug: screensDidWake (locked)"); self?.screensDidWake() } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { MainActor.assumeIsolated { Self.debugForceLocked = false } }
                }
            }
            // Debug: replay the sleep → system wake → display wake notification sequence.
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.lidfold.debugSleepWake"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    debugLog("debug: willSleep"); self?.willSleep()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated { debugLog("debug: systemDidWake"); self?.systemDidWake() } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { debugLog("debug: screensDidWake"); self?.screensDidWake() } }
                }
            }
        }
    }

    // MARK: demo

    private func runDemo(loop: Int = 0) {
        overlay.prewarm(closing: true)   // same as a real close starting
        let loops = Int(ProcessInfo.processInfo.environment["LF_DEMO_LOOPS"] ?? "1") ?? 1
        let start = CACurrentMediaTime()
        let close = 2.0, hold = 0.5, open = 2.0
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let e = CACurrentMediaTime() - start
                let p: Double
                if e < close { p = e / close }
                else if e < close + hold { p = 1 }
                else if e < close + hold + open { p = 1 - (e - close - hold) / open }
                else {
                    timer.invalidate()
                    // Same path as a real settle: clear, then free windows/snapshot/GPU objects.
                    self?.overlay.apply(0); self?.overlay.purgeIfHidden()
                    if loop + 1 < loops {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { debugLog("after fold \(loop + 1)"); self?.runDemo(loop: loop + 1) }
                        return
                    }
                    for t in [1.0, 3, 6] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { debugLog("\(t) s after teardown"); if t == 6 { NSApp.terminate(nil) } } }
                    return
                }
                if Int(e * 120) % 60 == 0 { debugLog(String(format: "demo p=%.2f", p)) }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self?.overlay.apply(max(0.001, min(1, p)))
                CATransaction.commit()
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: lifecycle

    private var asleep = false

    @objc private func willSleep() {
        guard Settings.enabled, !asleep, FoldOverlay.hasBuiltInScreen else { return }
        asleep = true
        tracker.prepareForSleep()   // overlay → fully dissolved, polling stops
        overlay.dropDesktopSnapshots()   // the desktop image is freed as the Mac goes to sleep / locks
        overlay.addLockCovers()
        debugLog("sleep: covers=\(overlay.hasLockSurfaces)")     // black cover above where the lock screen will be (see beginReveal)
        overlay.flush()
    }

    /// System woke, but the panel may still be dark: keep the overlay black and wait for the
    /// display (screensDidWake) before revealing, otherwise the opening plays unseen.
    @objc private func systemDidWake() {
        guard asleep else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.beginReveal() }   // fallback if screensDidWake never comes
        }
    }

    @objc private func screensDidWake() {
        // Failsafe: nothing may stay above the lock screen for more than 2 s after the display
        // wakes, whatever state the animation is in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.overlay.hasLockSurfaces else { return }
                debugLog("failsafe: removing lock-screen cover")
                self.tracker.stop()
                self.overlay.removeLockSurfaces()
                self.applyEnabled()
            }
        }
        guard asleep else { return }
        // Give the backlight a moment to come up so the opening is actually visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.wakeDelay) { [weak self] in
            MainActor.assumeIsolated { self?.beginReveal() }
        }
    }

    // MARK: lock screen

    /// True while the session is locked (lock screen / password prompt showing).
    static var screenIsLocked: Bool {
        if debugForceLocked { return true }
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
    nonisolated(unsafe) static var debugForceLocked = false

    /// The Mac locked: free any desktop snapshot immediately.
    @objc private func screenLocked() { overlay.dropDesktopSnapshots() }

    /// Unlocked mid-animation: take the lock-screen card down at once.
    @objc private func screenUnlocked() {
        guard overlay.hasLockSurfaces else { return }
        debugLog("unlocked: removing lock-screen surfaces")
        tracker.stop()
        overlay.removeLockSurfaces()
        applyEnabled()
    }

    private func beginReveal() {
        guard asleep else { return }   // run once
        asleep = false
        debugLog("reveal: locked=\(Self.screenIsLocked) covers=\(overlay.hasLockSurfaces)")
        guard Settings.enabled else { overlay.removeLockCovers(); overlay.apply(0); overlay.purgeIfHidden(); return }
        if Self.screenIsLocked && overlay.hasLockSurfaces {
            // Woke into the lock screen: capture the lock screen itself (cover excluded) and open it
            // as the glass card. If that's not possible, the cover plays the frosted live blur.
            // Either way, nothing from the unlocked desktop is ever shown above the lock screen.
            overlay.beginLockCard { [weak self] ok in
                guard let self else { return }
                if !ok { debugLog("lock card unavailable → frosted live blur"); self.overlay.enterLockMode() }
                if self.hasSensor { self.tracker.resumeAfterWake() } else { self.tracker.fadeOut(duration: Settings.wakeFade) }
            }
            return
        }
        overlay.removeLockCovers()     // unlocked (or no SkyLight): the glass card underneath is already black
        startOpening()
    }

    private func startOpening() {
        guard Settings.enabled else { overlay.apply(0); overlay.purgeIfHidden(); return }
        guard hasSensor else { tracker.fadeOut(duration: Settings.wakeFade); return }
        // The pre-sleep frame may have been dropped (displays reconfigure on wake): re-capture the
        // current desktop and wait briefly for it, so the card has content to open with.
        overlay.ensureSnapshots()
        let deadline = CACurrentMediaTime() + 0.5
        func start() {
            if overlay.snapshotsReady || CACurrentMediaTime() > deadline { tracker.resumeAfterWake(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { start() } }
        }
        start()
    }

    @objc private func screensChanged() {
        overlay.screensChanged()
        applyEnabled()
    }

    /// Poll only when it can matter: enabled, sensor present, built-in panel lit.
    /// (In clamshell mode the built-in screen disappears, so polling stops entirely.)
    private func applyEnabled() {
        guard !asleep else { return }
        if Settings.enabled && hasSensor && FoldOverlay.hasBuiltInScreen {
            if tracker.mode == .stopped { tracker.startIdle() }
        } else if tracker.mode != .fading {
            tracker.stop()
            overlay.apply(0)
            overlay.purgeIfHidden()
        }
    }

    // MARK: menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "LidFold")
        img?.isTemplate = true
        statusItem.button?.image = img

        let menu = NSMenu()
        menu.delegate = self
        if !hasSensor {
            let note = NSMenuItem(title: "No lid sensor — sleep/wake fade only", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(.separator())
        }
        enabledItem.target = self
        loginItem.target = self
        duoItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(duoItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LidFold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        enabledItem.state = Settings.enabled ? .on : .off
        let duoOn = Settings.style == .duo
        if duoOn && !ScreenSnapshot.hasPermission {
            duoItem.title = "Glass Card Effect — Allow Screen Recording…"
            duoItem.state = .mixed
        } else {
            duoItem.title = "Glass Card Effect"
            duoItem.state = duoOn ? .on : .off
        }
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        applyEnabled()
    }

    @objc private func toggleDuo() {
        if Settings.style == .duo {
            if ScreenSnapshot.hasPermission { UserDefaults.standard.set("classic", forKey: "style") }
            else { ScreenSnapshot.requestPermissionIfNeeded(force: true) }
        } else {
            UserDefaults.standard.set("duo", forKey: "style")
            ScreenSnapshot.requestPermissionIfNeeded(force: true)
        }
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
            if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = error.localizedDescription + "\n\nMove LidFold.app to /Applications and try again."
            NSApp.activate()
            a.runModal()
        }
    }
}

/// Development check: latency from creating a CADisplayLink to its first callbacks.
@MainActor
final class LinkTest: NSObject {
    static let shared = LinkTest()
    private var start: CFTimeInterval = 0
    private var n = 0
    private var link: CADisplayLink?
    private var round = 0
    func run() {
        n = 0
        start = CACurrentMediaTime()
        let screen = NSScreen.screens.first(where: { $0.isBuiltIn }) ?? NSScreen.main!
        let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }
    @objc func tick(_ l: CADisplayLink) {
        n += 1
        if n <= 3 { print(String(format: "round %d callback %d after %.1f ms", round, n, (CACurrentMediaTime() - start) * 1000)) }
        if n == 3 {
            l.invalidate(); link = nil; round += 1
            if round < 3 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.run() } } else { exit(0) }
        }
    }
}
