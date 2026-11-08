import AppKit
import ScreenCaptureKit

/// One-frame screen capture (never a stream) + Screen Recording permission handling.
enum ScreenSnapshot {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks once, with our own explanation first (macOS's prompt has no app-supplied text).
    /// Returns immediately; macOS applies a new grant after the app is relaunched.
    @MainActor
    static func requestPermissionIfNeeded(force: Bool = false) {
        guard !hasPermission else { return }
        let asked = UserDefaults.standard.bool(forKey: "askedScreenRecording")
        if asked && !force { return }
        UserDefaults.standard.set(true, forKey: "askedScreenRecording")

        let alert = NSAlert()
        alert.messageText = "Let LidFold see the screen for the fold effect?"
        alert.informativeText = """
        To fold the desktop away as a frosted glass card, LidFold takes a single still image of the \
        screen at the moment you start closing the lid. The image stays in memory only while \
        the animation runs and is then discarded. Nothing is recorded, saved, or sent anywhere.

        macOS will ask you to allow LidFold under Screen & System Audio Recording. Without it, \
        LidFold uses its frosted-glass effect instead.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Use Frosted Effect")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !CGRequestScreenCaptureAccess() {
            // Already denied once → macOS won't prompt again; open the settings pane instead.
            openSettings()
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Captures one frame of `displayID` at `size` pixels, excluding LidFold's own windows and the cursor.
    static func capture(displayID: CGDirectDisplayID, size: CGSize, native: Bool = false) async -> CGImage? {
        guard hasPermission else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let me = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.showsCursor = false
            config.capturesAudio = false
            config.colorSpaceName = CGColorSpace.displayP3
            // Points, not Retina pixels (¼ of the memory), except for the lock card, which ends
            // full-screen and sharp and must match the live lock screen pixel for pixel.
            config.captureResolution = native ? .best : .nominal
            config.queueDepth = 3                    // minimum buffer pool
            config.pixelFormat = kCVPixelFormatType_32BGRA
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
    }
}
