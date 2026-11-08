import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // belt and braces with LSUIElement: no Dock icon
    withExtendedLifetime(delegate) { app.run() }
}
