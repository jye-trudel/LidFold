import AppKit
import QuartzCore

/// Adaptive polling state machine:
///  • idle   – a coalesced low-rate timer (2 Hz, or 4 Hz near the fold zone); no rendering.
///  • active – CADisplayLink at up to 120 Hz while the lid moves.
///  • fading – a short timed ease-out (wake with lid already open, or sensor failure).
///
/// The sensor itself only produces a new value every ~100 ms (in jumps of up to ~8°), so the
/// angle is *reconstructed* per frame: each new sample starts a constant-speed glide to it,
/// timed to the observed sample interval (so steady motion never stalls between samples), and
/// a critically damped spring rounds off the speed changes. Cost: ~0.1 s behind the lid.
@MainActor
final class LidTracker: NSObject {
    enum Mode { case stopped, idle, active, fading }

    var onProgress: ((Double) -> Void)?
    var onSettled: (() -> Void)?
    var onActive: ((_ closing: Bool) -> Void)?
    private(set) var mode: Mode = .stopped
    private(set) var progress: Double = 0

    private let sensor: LidSensor
    private var idleTimer: DispatchSourceTimer?
    private var idleInterval: Double = 0
    private var link: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0

    private var anchor: Double = -1         // last raw angle counted as "movement"
    private var lastMoveTime: CFTimeInterval = 0
    private var readFailures = 0
    private var wakeDeadline: CFTimeInterval = 0   // while > now, keep trying to read after wake

    // Reconstruction state
    private var lastRaw: Double = -1
    private var lastReadTime: CFTimeInterval = 0
    private var lastChangeTime: CFTimeInterval = 0
    private var segFrom = 0.0, segTo = 0.0, segStart: CFTimeInterval = 0, segDur = 0.1
    private var shown = 0.0, shownVel = 0.0
    private var lidVel = 0.0                // °/s between sensor samples (for prediction)

    private var fadeFrom: Double = 0
    private var fadeStart: CFTimeInterval = 0
    private var fadeDuration: Double = 0.3

    private static let moveThreshold = 2.0  // degrees; >1° (sensor is integer-quantised)
    private static let readInterval = 0.014 // ≈70 Hz reads: catches each 10 Hz sample within ~1 frame

    // Push-rate calibration (per active burst)
    private var burstStart: CFTimeInterval = 0
    private var burstPushes = 0
    private var burstMin = 999.0, burstMax = -1.0
    private var tracer: Tracer?

    init(sensor: LidSensor) {
        self.sensor = sensor
        super.init()
        sensor.onPush = { [weak self] a in MainActor.assumeIsolated { self?.pushed(a) } }
    }

    // MARK: public control

    func startIdle() {
        stopLink()
        var fadeToClear = false
        if mode == .active {
            calibrate(); tracer?.event("idle"); tracer?.save(); tracer = nil
            fadeToClear = learnRest()
        }
        mode = .idle
        onSettled?()
        scheduleIdleTimer()
        if fadeToClear { fadeOut(duration: 0.3) }
    }

    /// The lid settled. If it's up near where it usually rests (opened wider, or repositioned by
    /// up to 15°), that is the new resting angle: the effect is remapped from there, and any slight
    /// frost left from the adjustment fades away. Bigger stops (e.g. halfway) keep their state.
    /// Returns true if a fade to clear is needed.
    private func learnRest() -> Bool {
        let raw = lastRaw
        guard raw > 75 else { return false }
        let rest = Settings.restAngle
        if raw >= rest - 15 {
            Settings.restAngle = raw
            return progress > 0
        }
        return false
    }

    func stop() {
        idleTimer?.cancel(); idleTimer = nil
        stopLink()
        mode = .stopped
    }

    /// Before sleep: freeze in the fully dissolved state so the panel wakes up covered.
    func prepareForSleep() {
        stop()
        emit(1)
    }

    /// After wake: the overlay is still fully dissolved. Track the lid from here, or fade out
    /// quickly if it's already open. If the sensor can't be read, keep retrying briefly, then
    /// fade out anyway — the screen must never be left covered.
    func resumeAfterWake() {
        stop()
        wakeDeadline = CACurrentMediaTime() + 2
        readFailures = 0
        sensor.open()   // the HID connection can go stale across sleep; re-arm pushes too
        guard let a = sensor.readAngle() else { goActive(); return }   // retries per frame
        beginTracking(fromAngle: a)
    }

    /// Timed ease-out from the current progress (used for no-sensor fallback too).
    func fadeOut(duration: Double) {
        idleTimer?.cancel(); idleTimer = nil
        guard progress > 0 else { startIdleIfSensor(); return }
        fadeFrom = progress
        fadeStart = CACurrentMediaTime()
        fadeDuration = duration
        mode = .fading
        startLink()
    }

    // MARK: idle

    /// Debug hook: start tracking exactly as a lid movement would.
    func debugBegin() {
        guard let a = sensor.readAngle() else { return }
        anchor = a + 3
        beginTracking(fromAngle: a)
    }

    private func scheduleIdleTimer() {
        // Poll faster only when the lid is close enough to the fold zone that a late start
        // would be visible; far above it, the slow rate is plenty.
        let near = anchor < 0 || anchor < Settings.effectStart + 25
        let interval: Double
        if Settings.pushOnChange == 1 { interval = 5 }
        else { interval = 1 / (near ? Settings.nearIdleHz : Settings.idleHz) }
        if idleTimer != nil, interval == idleInterval { return }
        idleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        // Leeway lets the kernel coalesce wakeups (lower energy); tighter when near the zone.
        let leeway = Int(interval * (near ? 100 : 400))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(leeway))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.idleTick() } }
        t.resume()
        idleTimer = t
        idleInterval = interval
    }

    private func idleTick() {
        guard let a = sensor.readAngle() else { return }
        if anchor < 0 {
            anchor = a
            if a > 75 { Settings.restAngle = a }   // first reading with the lid up: that's where it rests
            emit(Settings.progress(forAngle: a))
            scheduleIdleTimer()
            return
        }
        if abs(a - anchor) >= Self.moveThreshold { beginTracking(fromAngle: a) }
    }

    /// Pushed input report (~1 Hz heartbeat): a free extra movement detector while idle.
    private func pushed(_ a: Double) {
        if mode == .active { burstPushes += 1; tracer?.event("push \(a)"); return }
        guard mode == .idle else { return }
        if anchor < 0 { anchor = a; return }
        if abs(a - anchor) >= Self.moveThreshold { beginTracking(fromAngle: a) }
    }

    private func beginTracking(fromAngle a: Double) {
        let target = Settings.progress(forAngle: a)
        if progress > 0, target == 0, wakeDeadline > CACurrentMediaTime() {
            // Woke with the lid already wide open: short ease-out instead of a jump.
            anchor = a
            fadeOut(duration: Settings.wakeFade)
            return
        }
        goActive(closing: anchor < 0 || a < anchor)
        // Glide from where the effect currently *looks* to the new reading.
        newSample(a, at: CACurrentMediaTime())
        anchor = a
    }

    // MARK: active (display-synced)

    private func goActive(closing: Bool = true) {
        idleTimer?.cancel(); idleTimer = nil
        let now = CACurrentMediaTime()
        lastMoveTime = now
        burstStart = now; burstPushes = 0; burstMin = 999; burstMax = -1
        // Start the reconstruction from the angle the overlay currently represents.
        shown = progress > 0 ? Settings.angle(forProgress: progress) : max(anchor, Settings.effectStart)
        shownVel = 0
        segFrom = shown; segTo = shown; segStart = now; segDur = Settings.interp
        lastRaw = -1; lastChangeTime = 0; lastReadTime = 0; lidVel = 0
        tracer = Settings.trace ? Tracer() : nil
        tracer?.event("active anchor=\(anchor) progress=\(progress)")
        mode = .active
        let ta = CACurrentMediaTime()
        onActive?(closing)   // overlay builds windows (and snapshots, if closing) before they're needed
        tracer?.event(String(format: "onActive took %.1f ms", (CACurrentMediaTime() - ta) * 1000))
        startLink()
        tracer?.event("link started")
    }

    private func glidePosition(_ t: CFTimeInterval) -> Double {
        segFrom + (segTo - segFrom) * min(1, max(0, (t - segStart) / segDur))
    }

    /// A new sensor value arrived: glide to it, timed to the recent sample spacing.
    private func newSample(_ raw: Double, at t: CFTimeInterval) {
        let gap = lastChangeTime > 0 ? t - lastChangeTime : 0
        // Everything above openAngle looks identical (fully clear), so never spend glide time
        // travelling through it: start from openAngle at most. This removes the catch-up lag
        // when a close is first seen at, say, 107° and the next reading is already 70°.
        let ceiling = Settings.effectStart + 0.5
        var from = min(glidePosition(t), ceiling)
        if shown > ceiling { shown = ceiling; shownVel = 0 }
        let jump = abs(raw - from)
        if jump > 5 {
            // Big jump (fast lid, or a stall before this frame): catch up quickly.
            segDur = Settings.interp * 0.6
        } else {
            // Steady motion → glide lasts slightly longer than the gap, so it never stops between
            // samples. Slow motion (1° every few ticks) → longer glides instead of stop-go.
            segDur = gap > 0 ? min(0.4, max(Settings.interp, gap * 1.2)) : Settings.interp
        }
        if raw >= ceiling && from >= ceiling - 0.5 { from = raw }   // still invisible: just follow
        // Prediction: aim a little ahead in the direction the lid is moving (≤ predictCap°), which
        // halves the delay behind the lid. If the lid stops, `frame` drops the lead (see below).
        if gap > 0 && gap < 0.25 && lastRaw >= 0 { lidVel = 0.5 * lidVel + 0.5 * (raw - lastRaw) / gap } else { lidVel = 0 }
        let lead = max(-Settings.predictCap, min(Settings.predictCap, lidVel * Settings.predictLead))
        segFrom = from
        segTo = raw + lead
        segStart = t
        lastChangeTime = t
        lastRaw = raw
        burstMin = min(burstMin, raw); burstMax = max(burstMax, raw)
        if abs(raw - anchor) >= Self.moveThreshold { anchor = raw; lastMoveTime = t }
    }

    @objc private func frame(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = lastFrameTime > 0 ? min(0.05, l.timestamp - lastFrameTime) : l.duration
        lastFrameTime = l.timestamp

        if mode == .fading {
            let t = min(1, (now - fadeStart) / fadeDuration)
            let eased = 0.5 - 0.5 * cos(.pi * t)                // ease-in-out: a visible opening, no snap
            emit(fadeFrom * (1 - eased))
            if t >= 1 { emit(0); startIdleIfSensor() }
            return
        }

        var readMs = 0.0
        if now - lastReadTime >= Self.readInterval {
            lastReadTime = now
            guard let raw = sensor.readAngle() else {
                readFailures += 1
                // ~1 s of failures (or past the wake grace period): uncover the screen.
                if readFailures > 70 || (wakeDeadline > 0 && now > wakeDeadline) {
                    wakeDeadline = 0
                    fadeOut(duration: Settings.wakeFade)
                }
                return
            }
            readMs = (CACurrentMediaTime() - now) * 1000
            if readFailures > 0, wakeDeadline > 0 {          // first good read after wake
                readFailures = 0
                beginTracking(fromAngle: raw)
                return
            }
            readFailures = 0
            wakeDeadline = 0
            if raw != lastRaw { newSample(raw, at: now) }
        }
        // No new sample for 150 ms (the sensor updates every ~100 ms): the lid has stopped, so
        // drop the prediction and settle on the real angle.
        if lastRaw >= 0, now - lastChangeTime > 0.15, segTo != lastRaw {
            segFrom = glidePosition(now); segTo = lastRaw; segStart = now; segDur = Settings.interp
            lidVel = 0
        }

        // Linear glide → critically damped spring (C¹-smooth output).
        let target = glidePosition(now)
        shown = smoothDamp(shown, target, &shownVel, smoothTime: Settings.soften, dt: dt)
        emit(Settings.progress(forAngle: shown))
        tracer?.frame(dt: dt, readMs: readMs, raw: lastRaw, smooth: shown, progress: progress)

        if now - lastMoveTime > Settings.settleSeconds, abs(shown - lastRaw) < 0.05 {
            shown = lastRaw
            anchor = lastRaw
            emit(Settings.progress(forAngle: lastRaw))
            startIdle()
        }
    }

    // MARK: helpers

    /// After a burst with real movement, learn whether the sensor pushes reports while moving.
    /// If it does (≥ 8/s), idle polling is unnecessary and is reduced to a 5 s safety net.
    private func calibrate() {
        let span = CACurrentMediaTime() - burstStart - Settings.settleSeconds
        guard span > 0.3, burstMax - burstMin >= 15 else { return }
        let rate = Double(burstPushes) / span
        let learned = rate >= 8 ? 1 : (rate <= 3 ? 0 : Settings.pushOnChange)
        if learned != Settings.pushOnChange { Settings.pushOnChange = learned }
    }

    private func startIdleIfSensor() {
        if sensor.isOpen { startIdle() } else { stopLink(); mode = .stopped }
    }

    private func startLink() {
        guard link == nil else { return }
        let screen = NSScreen.screens.first(where: { $0.isBuiltIn }) ?? NSScreen.main
        guard let screen else { return }
        let l = screen.displayLink(target: self, selector: #selector(frame(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        lastFrameTime = 0
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private func emit(_ p: Double) {
        guard p != progress else { return }
        progress = p
        onProgress?(p)
    }
}

/// Critically damped spring toward `target` (Game Programming Gems 4, "smooth damp").
private func smoothDamp(_ current: Double, _ target: Double, _ vel: inout Double,
                        smoothTime: Double, dt: Double) -> Double {
    let omega = 2 / smoothTime
    let x = omega * dt
    let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
    let change = current - target
    let temp = (vel + omega * change) * dt
    vel = (vel - omega * temp) * decay
    return target + (change + temp) * decay
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }
}

/// Debug trace (only when `trace` is on): one CSV per lid movement, appended to
/// ~/Library/Logs/LidFold-trace.csv. Buffered in memory, written once when the lid settles.
private final class Tracer {
    private let t0 = CACurrentMediaTime()
    private var out = ""
    private var ms: String { String(format: "%.1f", (CACurrentMediaTime() - t0) * 1000) }
    func event(_ s: String) { out += "\(ms),#\(s)\n" }
    func frame(dt: Double, readMs: Double, raw: Double, smooth: Double, progress: Double) {
        out += "\(ms),\(String(format: "%.1f,%.2f,%.0f,%.2f,%.3f", dt * 1000, readMs, raw, smooth, progress))\n"
    }
    func save() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LidFold-trace.csv")
        let header = "# burst \(Date())\nms,dt_ms,read_ms,raw,smooth,progress\n"
        guard let data = (header + out).data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }
}
