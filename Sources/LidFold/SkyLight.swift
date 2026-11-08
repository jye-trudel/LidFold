import AppKit

/// Minimal private-SkyLight helper to show a window above the lock screen, after the approach in
/// github.com/Lakr233/SkyLightWindow (MIT): create a space, give it an absolute level above the
/// screen-lock level, show it, and move the window into it.
///
/// Every symbol is resolved with dlsym and checked; if any is missing (a future macOS), this
/// reports unavailable and LidFold simply skips the lock-screen effect.
///
/// Only LidFold's black cover / live-blur windows are ever put here, never the glass card (whose
/// snapshot is the desktop).
enum SkyLight {
    private typealias FMainConnectionID = @convention(c) () -> Int32
    private typealias FSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias FSpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias FShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias FSpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private struct Functions {
        let mainConnectionID: FMainConnectionID
        let spaceCreate: FSpaceCreate
        let spaceSetAbsoluteLevel: FSpaceSetAbsoluteLevel
        let showSpaces: FShowSpaces
        let addWindowsAndRemoveFromSpaces: FSpaceAddWindowsAndRemoveFromSpaces
    }

    /// Space absolute levels (from the reference): screen lock = 300; 400 is
    /// "notification centre at screen lock", i.e. just above the lock screen.
    private static var aboveLockScreenLevel: Int32 {
        let v = UserDefaults.standard.integer(forKey: "lockSpaceLevel")
        return v > 0 ? Int32(v) : 400
    }

    private static let functions: Functions? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW) else {
            return nil
        }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let a = sym("SLSMainConnectionID", FMainConnectionID.self),
              let b = sym("SLSSpaceCreate", FSpaceCreate.self),
              let c = sym("SLSSpaceSetAbsoluteLevel", FSpaceSetAbsoluteLevel.self),
              let d = sym("SLSShowSpaces", FShowSpaces.self),
              let e = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", FSpaceAddWindowsAndRemoveFromSpaces.self)
        else { return nil }
        return Functions(mainConnectionID: a, spaceCreate: b, spaceSetAbsoluteLevel: c, showSpaces: d,
                         addWindowsAndRemoveFromSpaces: e)
    }()

    nonisolated(unsafe) private static var connection: Int32 = 0
    nonisolated(unsafe) private static var space: Int32 = 0

    static var isAvailable: Bool { functions != nil }


    /// Moves `window` into the above-lock-screen space (created once, on first use).
    /// Returns false (and does nothing) if SkyLight is unavailable or the space can't be made.
    @MainActor @discardableResult
    static func moveAboveLockScreen(_ window: NSWindow) -> Bool {
        guard let f = functions, window.windowNumber > 0 else { return false }
        if space == 0 {
            connection = f.mainConnectionID()
            let sid = f.spaceCreate(connection, 1, 0)
            guard sid != 0 else { return false }
            _ = f.spaceSetAbsoluteLevel(connection, sid, aboveLockScreenLevel)
            _ = f.showSpaces(connection, [NSNumber(value: sid)] as CFArray)
            space = sid
        }
        // Flag 7 as in the reference: add to this space and remove from the window's other spaces.
        let err = f.addWindowsAndRemoveFromSpaces(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        debugLog("SkyLight: window \(window.windowNumber) → space \(space) (err \(err))")
        return err == 0
    }
}
