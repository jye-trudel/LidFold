import Foundation

/// All tunables live in UserDefaults (domain `local.lidfold`), so they can be changed with
/// `defaults write local.lidfold <key> <value>` without rebuilding. Values are re-read at the
/// start of every lid movement, so changes apply without restarting the app.
enum Settings {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "enabled": true,
            "openAngle": 105.0,     // fallback resting angle until LidFold has learned yours ("restAngle")
            "deadZone": 12.0,       // degrees of closing from rest before the effect starts
            "closedAngle": 20.0,    // ≤ this many degrees: fully dissolved
            "idleHz": 2.0,          // idle poll rate when the lid is well above openAngle
            "nearIdleHz": 4.0,      // idle poll rate within 25° of openAngle (catches the start of a close)
            "settleSeconds": 1.0,   // no movement for this long → back to idle rate
            "wakeFadeMs": 900.0,    // opening animation on wake when the lid is already open
            "wakeDelayMs": 150.0,   // wait after the display wakes (backlight coming up) before opening
            "allScreens": false,
            "interpMs": 110.0,      // glide time to each new sensor sample (sensor updates ~every 100 ms)
            "softenMs": 50.0,
            "predictMs": 60.0,      // aim this far ahead of the lid (halves the delay); 0 = off
            "predictCap": 3.0,      // max prediction, degrees (= max overshoot when the lid stops)       // spring that rounds off speed changes between glides
            "trace": false,
            "style": "duo",         // "duo" (frosted glass card, needs Screen Recording), "classic" or "eclipse" (live-blur fallbacks)
            "frostRadius": 36.0,    // frost blur radius at full fold, in points
            "cardTilt": 30.0,       // degrees of lean-back at full fold
            "cardScale": 0.88,      // card size at full fold (1 = full screen)
            "cardCorner": 26.0,     // card corner radius at full fold, points
            "cardPerspective": 1300.0, // perspective distance, points (m34 = −1/this); smaller = stronger
            "cardLift": 0.35,       // how far the shrunken card floats off the bottom edge (fraction of the shrink)
            "snapshotScale": 1.0,   // Duo snapshot resolution in pixels per point (1 = half of Retina; it's blurred anyway)
            "corona": 0.22,         // eclipse rim brightness, 0 = off         // write a per-frame CSV to ~/Library/Logs/LidFold-trace.csv
            "pushOnChange": -1,     // auto-detected: 1 = sensor pushes reports while moving (no idle polling needed)    // also cover external displays (off: only the built-in panel folds)
        ])
    }

    static var enabled: Bool { get { d.bool(forKey: "enabled") } set { d.set(newValue, forKey: "enabled") } }
    static var openAngle: Double { d.double(forKey: "openAngle") }
    static var deadZone: Double { max(0, min(20, d.double(forKey: "deadZone"))) }
    /// The angle the lid normally rests at (learned; see LidTracker). The effect is mapped from
    /// here: closing starts a few degrees below it, opening reaches full clarity back at it.
    static var restAngle: Double {
        get { let v = d.double(forKey: "restAngle"); return v > 0 ? v : openAngle }
        set { d.set(newValue, forKey: "restAngle") }
    }
    /// Angle at which the effect starts (fully clear at or above it).
    static var effectStart: Double { min(140, max(closedAngle + 25, restAngle - deadZone)) }
    static var closedAngle: Double { d.double(forKey: "closedAngle") }
    static var idleHz: Double { max(0.5, min(10, d.double(forKey: "idleHz"))) }
    static var settleSeconds: Double { max(0.2, d.double(forKey: "settleSeconds")) }
    static var wakeFade: Double { max(0.05, d.double(forKey: "wakeFadeMs") / 1000) }
    static var wakeDelay: Double { max(0, min(2, d.double(forKey: "wakeDelayMs") / 1000)) }
    static var allScreens: Bool { d.bool(forKey: "allScreens") }
    static var nearIdleHz: Double { max(0.5, min(20, d.double(forKey: "nearIdleHz"))) }
    static var interp: Double { max(0.02, d.double(forKey: "interpMs") / 1000) }
    static var predictLead: Double { max(0, min(0.2, d.double(forKey: "predictMs") / 1000)) }
    static var predictCap: Double { max(0, min(10, d.double(forKey: "predictCap"))) }
    static var soften: Double { max(0.001, d.double(forKey: "softenMs") / 1000) }
    static func angle(forProgress p: Double) -> Double {
        let open = effectStart, closed = min(closedAngle, open - 1)
        return open - p * (open - closed)
    }
    static var trace: Bool { d.bool(forKey: "trace") }
    enum Style: String { case duo, eclipse, classic }
    static var style: Style { Style(rawValue: d.string(forKey: "style") ?? "") ?? .duo }
    static var frostRadius: Double { max(0, min(150, d.double(forKey: "frostRadius"))) }
    static var cardTilt: Double { max(0, min(80, d.double(forKey: "cardTilt"))) }
    static var cardScale: Double { max(0.3, min(1, d.double(forKey: "cardScale"))) }
    static var cardCorner: Double { max(0, d.double(forKey: "cardCorner")) }
    static var cardPerspective: Double { max(200, d.double(forKey: "cardPerspective")) }
    static var cardLift: Double { max(0, min(1, d.double(forKey: "cardLift"))) }
    static var snapshotScale: Double { max(0.25, min(2, d.double(forKey: "snapshotScale"))) }
    static var corona: Double { max(0, min(1, d.double(forKey: "corona"))) }
    /// -1 unknown, 0 no, 1 yes. Learned from real lid movements (see LidTracker.calibrate).
    static var pushOnChange: Int { get { d.integer(forKey: "pushOnChange") } set { d.set(newValue, forKey: "pushOnChange") } }

    /// Lid angle → fold progress (0 = clear, 1 = fully dissolved).
    static func progress(forAngle a: Double) -> Double {
        let open = effectStart, closed = min(closedAngle, open - 1)
        return min(1, max(0, (open - a) / (open - closed)))
    }
}
