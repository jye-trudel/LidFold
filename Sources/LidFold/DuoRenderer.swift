import AppKit
import Metal
import QuartzCore

/// GPU frosted-glass blur of a captured frame.
///
/// The frame is uploaded once into a mipmapped texture (a compute kernel builds the mip chain). Each
/// frame, a compute kernel blurs it with a 32-tap Vogel-disc pattern, rotated per pixel and
/// read from the mip level matching the blur radius, so the frost is smooth and isotropic
/// (no streaks) at any strength, for the same cost.
///
/// The shader is compiled from source at runtime (no Xcode Metal toolchain needed); macOS
/// caches the compiled result, so later compiles are fast.
@MainActor
final class DuoRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState   // compute-only: avoids the render pipeline's
                                                    // ~35 MB per-process tiler allocation
    private let downsample: MTLComputePipelineState // our own mip builder (blit.generateMipmaps costs ~85 MB)

    private var lastCommandBuffer: MTLCommandBuffer?

    /// Blocks until the GPU is done with every frame submitted so far (call before freeing).
    func finish() {
        lastCommandBuffer?.waitUntilCompleted()
        lastCommandBuffer = nil
    }

    static func make() -> DuoRenderer? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try? DuoRenderer(device: device)
    }

    private init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw NSError(domain: "LidFold", code: 1) }
        queue = q
        let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
        pipeline = try device.makeComputePipelineState(function: lib.makeFunction(name: "fold")!)
        downsample = try device.makeComputePipelineState(function: lib.makeFunction(name: "halve")!)
    }

    // MARK: snapshot → mipmapped texture

    final class Snapshot {
        let texture: MTLTexture
        let width: Int, height: Int
        let colorSpace: CGColorSpace
        var pixelsPerPoint: Double = 1     // so the frost radius (in points) looks the same at any resolution
        init(texture: MTLTexture, width: Int, height: Int, colorSpace: CGColorSpace) {
            self.texture = texture; self.width = width; self.height = height; self.colorSpace = colorSpace
        }
    }

    /// Uploads `image` (drawn at `size` pixels) and builds its mip chain with a compute kernel.
    func makeSnapshot(_ image: CGImage, size: CGSize) -> Snapshot? {
        autoreleasepool { buildSnapshot(image, size: size) }   // free the CPU staging copies right away
    }

    private func buildSnapshot(_ image: CGImage, size: CGSize) -> Snapshot? {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        td.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        td.storageMode = .private
        guard let tex = device.makeTexture(descriptor: td) else { return nil }

        // CPU → staging texture (keeps the display's colour space: vivid colours).
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        sd.storageMode = .shared
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let staging = device.makeTexture(descriptor: sd) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        staging.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)

        // Unretained references (see `render`); we wait below, so `staging` outlives the GPU work.
        guard let cb = queue.makeCommandBufferWithUnretainedReferences(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
                  sourceSize: MTLSizeMake(w, h, 1), to: tex, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOriginMake(0, 0, 0))
        blit.endEncoding()
        // Mip chain: each level = 2×2 average of the previous one (compute, no render pipeline).
        guard let ce = cb.makeComputeCommandEncoder() else { return nil }
        ce.setComputePipelineState(downsample)
        for level in 1..<tex.mipmapLevelCount {
            guard let src = tex.makeTextureView(pixelFormat: .rgba8Unorm, textureType: .type2D,
                                                levels: (level - 1)..<level, slices: 0..<1),
                  let dst = tex.makeTextureView(pixelFormat: .rgba8Unorm, textureType: .type2D,
                                                levels: level..<(level + 1), slices: 0..<1) else { break }
            ce.setTexture(src, index: 0)
            ce.setTexture(dst, index: 1)
            ce.dispatchThreads(MTLSizeMake(dst.width, dst.height, 1), threadsPerThreadgroup: MTLSizeMake(16, 16, 1))
            ce.memoryBarrier(scope: .textures)
        }
        ce.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()      // a few ms, once per close
        return Snapshot(texture: tex, width: w, height: h, colorSpace: space)
    }

    // MARK: per-frame render

    struct Uniforms {
        var width: Float = 1, height: Float = 1  // snapshot pixels
        var hasSnapshot: Float = 0
        var radius: Float = 0        // frost blur radius, snapshot pixels
        var darkMax: Float = 0       // shadow on the far (top) part of the card
        var dissolve: Float = 0      // final fade to black
        var card: Float = 0          // 0…1: opaque card (whole frame shown, sharp where unblurred)
        var frost: Float = 0         // 0…1: light haze + saturation, like Apple's materials
    }

    /// Fold progress → shader parameters (shared ease-in with the card tilt).
    static func uniforms(progress p: Double, snapshot: Snapshot?) -> Uniforms {
        var u = Uniforms()
        let e = Float(Card.eased(p))
        if let s = snapshot {
            u.width = Float(s.width)
            u.height = Float(s.height)
            u.hasSnapshot = 1
        }
        u.radius = Float(Settings.frostRadius * (snapshot?.pixelsPerPoint ?? 1)) * e
        u.darkMax = 0.75 * e
        u.frost = min(1, e * 2)
        u.card = u.hasSnapshot * Float(Card.opacity(p))
        let d = Float(min(1, max(0, (p - 0.85) / 0.15)))
        u.dissolve = d * d * (3 - 2 * d)
        return u
    }

    func render(progress p: Double, snapshot: Snapshot?, to target: MTLTexture,
                present drawable: CAMetalDrawable? = nil, inTransaction: Bool = false, wait: Bool = false) {
        // Unretained references: Metal's pooled command-buffer storage otherwise keeps the last
        // frame's drawable (→ layer → window) alive indefinitely, pinning ~35 MB after teardown.
        // Lifetimes are ours instead: `finish()` waits for the last frame before anything is freed.
        guard let cb = queue.makeCommandBufferWithUnretainedReferences(), let enc = cb.makeComputeCommandEncoder() else { return }
        lastCommandBuffer = cb
        var u = Self.uniforms(progress: p, snapshot: snapshot)
        enc.setComputePipelineState(pipeline)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setTexture(snapshot?.texture, index: 0)
        enc.setTexture(target, index: 1)
        enc.dispatchThreads(MTLSizeMake(target.width, target.height, 1), threadsPerThreadgroup: MTLSizeMake(16, 16, 1))
        enc.endEncoding()
        if inTransaction {
            // presentsWithTransaction: the new frame appears in the same CA commit as the card
            // transform, so the image and the tilt can never be a frame apart.
            cb.commit()
            cb.waitUntilScheduled()
            drawable?.present()
        } else {
            if let drawable { cb.present(drawable) }
            cb.commit()
        }
        if wait { cb.waitUntilCompleted() }
    }

    // MARK: shader

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct U {
        float width, height, hasSnapshot, radius;
        float darkMax, dissolve, card, frost;
    };

    kernel void fold(texture2d<float> snap [[texture(0)]],
                     texture2d<float, access::write> out [[texture(1)]],
                     constant U& u [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());   // uv.y = 0 at the top
        float t = 1.0 - uv.y;                                // 0 at the hinge (bottom) … 1 at the top

        // Shadow on the far part of the tilted pane, then the final dissolve.
        float dark = u.darkMax * (0.15 + 0.85 * pow(t, 1.5));
        dark = mix(dark, 1.0, u.dissolve);

        // Cover the live desktop once frosted, or everywhere once the card is opaque.
        float a = max(u.hasSnapshot * saturate(u.radius / 1.5), u.card);
        float3 col = float3(0.0);
        if (a > 0.0 && dark < 0.999) {
            if (u.radius < 0.5) {
                col = snap.sample(s, uv, level(0.0)).rgb;
            } else {
                // 32-tap Vogel disc with Gaussian weights, rotated per pixel (interleaved-gradient
                // noise) and read from the mip level matching the tap spacing: smooth, even frost.
                const int N = 32;
                float noise = fract(52.9829189 * fract(dot(float2(gid), float2(0.06711056, 0.00583715))));
                float lod = max(0.0, log2(u.radius / 5.0));      // finer than the tap spacing: no blockiness
                float2 px = 1.0 / float2(u.width, u.height);
                float3 acc = 0.0;
                float wsum = 0.0;
                for (int i = 0; i < N; i++) {
                    float r = sqrt((float(i) + 0.5) / float(N));
                    float ang = float(i) * 2.39996323 + noise * 6.2831853;
                    float2 o = float2(cos(ang), sin(ang)) * r * u.radius * px;
                    float w = exp(-2.0 * r * r);
                    acc += snap.sample(s, uv + o, level(lod)).rgb * w;
                    wsum += w;
                }
                col = acc / wsum;
            }
            // Frost: a touch more saturation and a light haze, like Apple's glass materials.
            float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
            col = mix(float3(luma), col, 1.0 + 0.15 * u.frost);
            col = mix(col, float3(1.0), 0.06 * u.frost);
            col = saturate(col);
        }
        // Premultiplied: frosted card (alpha a) over the desktop, then black (alpha dark) on top.
        float A = 1.0 - (1.0 - dark) * (1.0 - a);
        out.write(float4(col * a * (1.0 - dark), A), gid);
    }

    kernel void halve(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        uint2 m = uint2(src.get_width() - 1, src.get_height() - 1);
        uint2 p = gid * 2;
        float4 c = src.read(min(p, m)) + src.read(min(p + uint2(1, 0), m))
                 + src.read(min(p + uint2(0, 1), m)) + src.read(min(p + uint2(1, 1), m));
        dst.write(c * 0.25, gid);
    }
    """
}
