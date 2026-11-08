import AppKit
import Metal
import QuartzCore

/// Offscreen check of the Duo shader: draws a synthetic desktop (wallpaper + windows), runs the
/// real DuoRenderer at several fold amounts and writes PNGs. Used during development only.
@MainActor
enum RenderTest {
    static func run(outDir: String) {
        guard let r = DuoRenderer.make() else { print("no Metal"); return }
        let w = 1512, h = 982
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic") as CFURL, nil),
           let wp = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            ctx.draw(wp, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        func win(_ x: Int, _ y: Int, _ ww: Int, _ hh: Int, _ c: NSColor, _ title: String) {
            let r = CGRect(x: x, y: y, width: ww, height: hh)
            ctx.setFillColor(NSColor.white.cgColor); ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
            ctx.setFillColor(c.cgColor); ctx.fill(CGRect(x: x, y: y + hh - 34, width: ww, height: 34))
            for (i, col) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                ctx.setFillColor(col.cgColor); ctx.fillEllipse(in: CGRect(x: x + 12 + i * 20, y: y + hh - 24, width: 12, height: 12))
            }
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current = ns
            (title as NSString).draw(at: NSPoint(x: x + 80, y: y + hh - 26), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
            for line in 0..<Int(hh / 28) - 2 {
                ("The quick brown fox jumps over the lazy dog \(line)" as NSString).draw(at: NSPoint(x: x + 16, y: y + hh - 70 - line * 26), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black])
            }
            NSGraphicsContext.current = nil
        }
        win(80, 360, 620, 520, .systemBlue, "Safari")
        win(760, 120, 640, 460, .systemOrange, "Notes")
        ctx.setFillColor(NSColor(white: 0.15, alpha: 0.85).cgColor); ctx.fill(CGRect(x: 0, y: h - 30, width: w, height: 30)) // menu bar
        ctx.setFillColor(NSColor(white: 1, alpha: 0.35).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 456, y: 8, width: 600, height: 70), cornerWidth: 20, cornerHeight: 20, transform: nil)); ctx.fillPath() // dock
        let desktop = ctx.makeImage()!
        save(desktop, "\(outDir)/duo-0-source.png")

        guard let snap = r.makeSnapshot(desktop, size: CGSize(width: w, height: h)) else { print("snapshot failed"); return }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.shaderWrite]; td.storageMode = .shared
        let target = r.device.makeTexture(descriptor: td)!
        for p in [0.3, 0.5, 0.65, 0.8, 0.92, 0.97] {
            r.render(progress: p, snapshot: snap, to: target, wait: true)
            // Composite the premultiplied overlay over the (sharp) desktop, as WindowServer would.
            var px = [UInt8](repeating: 0, count: w * h * 4)
            target.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            out.draw(desktop, in: CGRect(x: 0, y: 0, width: w, height: h))
            let ovCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            px.withUnsafeBytes { ovCtx.data!.copyMemory(from: $0.baseAddress!, byteCount: w * h * 4) }   // image owns its pixels
            let ov = ovCtx.makeImage()!
            out.draw(ov, in: CGRect(x: 0, y: 0, width: w, height: h))
            save(out.makeImage()!, "\(outDir)/duo-p\(Int(p * 100)).png")
            // Same layer tree as DuoWindow (live desktop underneath, backdrop, tilted card), rendered
            // by Core Animation itself — verifies the hinge, direction and perspective.
            if let img = composite(desktop: desktop, overlay: ov, p: p, w: w, h: h, device: r.device) {
                save(img, "\(outDir)/card-p\(Int(p * 100)).png")
            }
        }
        // Timing: 120 renders.
        let t0 = CACurrentMediaTime()
        for i in 0..<120 { r.render(progress: 0.3 + Double(i) / 200, snapshot: snap, to: target, wait: i == 119) }
        print(String(format: "avg GPU+CPU per frame: %.2f ms", (CACurrentMediaTime() - t0) / 120 * 1000))
    }

    private static func composite(desktop: CGImage, overlay: CGImage, p: Double, w: Int, h: Int, device: MTLDevice) -> CGImage? {
        let size = CGSize(width: w, height: h)
        CATransaction.begin(); CATransaction.setDisableActions(true)   // no implicit fades in the snapshot
        let root = CALayer(); root.frame = CGRect(origin: .zero, size: size)
        let live = CALayer(); live.frame = root.bounds; live.contents = desktop
        let host = CALayer(), card = CALayer(), content = CALayer()
        host.frame = root.bounds
        Card.configure(container: card, host: host, size: size)
        content.frame = card.bounds; content.contents = overlay
        card.addSublayer(content)
        host.addSublayer(card)
        root.addSublayer(live); root.addSublayer(host)
        Card.apply(p, container: card, host: host, size: size)
        CATransaction.commit()
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        guard let queue = device.makeCommandQueue() else { return nil }
        let car = CARenderer(mtlTexture: tex, options: [kCARendererMetalCommandQueue as String: queue])
        car.layer = root
        car.bounds = root.bounds
        CATransaction.flush()
        car.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        car.addUpdate(root.bounds)
        car.render()
        car.endFrame()
        let done = queue.makeCommandBuffer()!   // same queue → completes after CA's work
        done.commit(); done.waitUntilCompleted()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let dst = ctx.data else { return nil }
        tex.getBytes(dst, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return ctx.makeImage()
    }

    private static func save(_ img: CGImage, _ path: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
