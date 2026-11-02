import Foundation

/// CPU execution of tip `MetalVolumetricLight` kernels (`volumetricBeams`, `volumetricCombine`).
enum VolumetricLightCompute {

    // Portable stand-ins for Apple's `simd` module (not shipped as a Swift module on Linux).
    private static func dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a * b).sum() }
    private static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
    private static func length(_ v: SIMD2<Float>) -> Float { (v * v).sum().squareRoot() }
    private static func length(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }
    private static func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let len = length(v)
        return len > 1e-8 ? v / len : .zero
    }
    private static func max3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(max(a.x, b.x), max(a.y, b.y), max(a.z, b.z))
    }
    private static func min3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(min(a.x, b.x), min(a.y, b.y), min(a.z, b.z))
    }
    private static func mix3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
    static func execute(_ encoder: MTLComputeCommandEncoder) throws {
        let combine = encoder.pipeline?.name == "volumetricCombine"
        guard encoder.ended, let data = encoder.bytes[0], data.count >= 128 else {
            throw NSError(domain: "Compositor.VolumetricLightCompute", code: 1)
        }
        if combine {
            try runCombine(encoder, data: data)
        } else {
            try runBeams(encoder, data: data)
        }
    }

    private struct Params {
        var color: SIMD3<Float>
        var tint: SIMD3<Float>
        var offsets: [SIMD2<Float>] // 6 inputs
        var light: SIMD2<Float>
        var side: Float
        var size: Float
        var length: Float
        var shafts: Float
        var haze: Float
        var height: Float
        var top: Float
        var hasDepth: Float
        var start: Float
        var end: Float
    }

    private static func loadParams(_ data: Data) -> Params {
        func f(_ offset: Int) -> Float {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
        }
        var offsets = [SIMD2<Float>](repeating: .zero, count: 6)
        for i in 0..<6 {
            let base = 32 + (i / 2) * 16 + (i % 2) * 8
            offsets[i] = SIMD2(f(base), f(base + 4))
        }
        return Params(
            color: SIMD3(f(0), f(4), f(8)),
            tint: SIMD3(f(16), f(20), f(24)),
            offsets: offsets,
            light: SIMD2(f(80), f(84)),
            side: f(88), size: f(92), length: f(96), shafts: f(100), haze: f(104),
            height: f(108), top: f(112), hasDepth: f(116), start: f(120), end: f(124)
        )
    }

    private static func pixels(_ texture: MTLTexture) throws -> [Float] {
        guard texture.width > 0, texture.height > 0,
              [.rgba16Float, .rgba32Float].contains(texture.pixelFormat),
              texture.rgbaBytes.count == texture.width * texture.height * texture.bytesPerPixel else {
            throw NSError(domain: "Compositor.VolumetricLightCompute", code: 2)
        }
        return texture.rgbaBytes.withUnsafeBytes { bytes in
            (0..<(texture.width * texture.height * 4)).map {
                texture.pixelFormat == .rgba16Float
                    ? Float(Float16(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)))
                    : bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self)
            }
        }
    }

    private static func store(_ values: [Float], into texture: MTLTexture) {
        texture.rgbaBytes = texture.pixelFormat == .rgba16Float
            ? values.map { Float16($0) }.withUnsafeBytes { Array($0) }
            : values.withUnsafeBytes { Array($0) }
    }

    private static func texel(_ px: [Float], _ w: Int, _ h: Int, _ x: Int, _ y: Int) -> SIMD4<Float> {
        let cx = min(w - 1, max(0, x)), cy = min(h - 1, max(0, y))
        let i = (cy * w + cx) * 4
        return SIMD4(px[i], px[i + 1], px[i + 2], px[i + 3])
    }

    /// Pixel-coord bilinear sample, clamp-to-edge (Metal `coord::pixel`).
    private static func sample(_ px: [Float], _ w: Int, _ h: Int, _ at: SIMD2<Float>) -> SIMD4<Float> {
        let x = at.x - 0.5, y = at.y - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let tx = x - Float(x0), ty = y - Float(y0)
        let a = texel(px, w, h, x0, y0)
        let b = texel(px, w, h, x0 + 1, y0)
        let c = texel(px, w, h, x0, y0 + 1)
        let d = texel(px, w, h, x0 + 1, y0 + 1)
        let top = a + (b - a) * tx
        let bottom = c + (d - c) * tx
        return top + (bottom - top) * ty
    }

    private static func hash(_ n: Float) -> Float {
        fract(sin(n * 12.9898) * 43758.5453)
    }

    private static func fract(_ v: Float) -> Float { v - floor(v) }

    private static func around(angle: Float, cells: Float, seed: Float) -> Float {
        let u = (angle / 6.2831853 + 0.5) * cells
        let i = floor(u)
        var f = u - i
        f = f * f * (3 - 2 * f)
        return mix(hash(fmod(i, cells) + seed), hash(fmod(i + 1, cells) + seed), f)
    }

    private static func fmod(_ a: Float, _ b: Float) -> Float {
        a - b * floor(a / b)
    }

    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - edge0) / max(1e-8, edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private static func emission(image: [Float], iw: Int, ih: Int,
                                 subject: [Float], sw: Int, sh: Int,
                                 peak: Float, p: Params, at: SIMD2<Float>) -> Float {
        let color = sample(image, iw, ih, at + p.offsets[0])
        let bright = min(1, max(0, dot(SIMD3(color.x, color.y, color.z),
                                            SIMD3(0.2126, 0.7152, 0.0722)) / peak))
        let blocked = sample(subject, sw, sh, at + p.offsets[1]).x
        let apart = at - p.light
        let distance = length(apart)
        let open = min(1, max(0, (bright - 0.08) / 0.3))
        let disc = exp(-2 * (distance / max(1e-6, p.size)) * (distance / max(1e-6, p.size)))
        let openings = min(1, max(0, (bright - 0.45) / 0.45)) * exp(-distance / (p.side * 0.5))
        let angle = atan2(apart.y, apart.x)
        let wave = 0.6 * around(angle: angle, cells: 97, seed: 3.1)
            + 0.4 * around(angle: angle, cells: 251, seed: 7.7)
        let broken = 1 - p.shafts + p.shafts * wave * wave * 1.8
        return (disc * (0.25 + 0.75 * open) + openings) * (1 - blocked) * broken
    }

    private static func runBeams(_ encoder: MTLComputeCommandEncoder, data: Data) throws {
        guard let imageT = encoder.textures[0], let subjectT = encoder.textures[1],
              let peakT = encoder.textures[2], let resultT = encoder.textures[3] else {
            throw NSError(domain: "Compositor.VolumetricLightCompute", code: 3)
        }
        let p = loadParams(data)
        let w = resultT.width, h = resultT.height
        let image = try pixels(imageT)
        let subject = try pixels(subjectT)
        let peakPx = try pixels(peakT)
        let brightest = max(0.05, peakPx[1]) // .g of the single peak pixel
        let iw = imageT.width, ih = imageT.height
        let sw = subjectT.width, sh = subjectT.height
        var result = [Float](repeating: 0, count: w * h * 4)
        let samples = 96
        for y in 0..<h {
            for x in 0..<w {
                let here = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                let step = (p.light - here) * p.length / Float(samples)
                let jitter = hash(Float(x) * 0.618 + Float(y) * 1.414)
                var sum: Float = 0, weight: Float = 1
                for i in 0..<samples {
                    let at = here + step * (Float(i) + jitter)
                    sum += emission(image: image, iw: iw, ih: ih, subject: subject, sw: sw, sh: sh,
                                    peak: brightest, p: p, at: at) * weight
                    weight *= 0.985
                }
                let gathered = sum / Float(samples) * 4
                let i = (y * w + x) * 4
                result[i] = gathered; result[i + 1] = gathered; result[i + 2] = gathered; result[i + 3] = 1
            }
        }
        store(result, into: resultT)
    }

    private static func runCombine(_ encoder: MTLComputeCommandEncoder, data: Data) throws {
        guard let imageT = encoder.textures[0], let beamsT = encoder.textures[1],
              let nearT = encoder.textures[2], let glowsT = encoder.textures[3],
              let ambientT = encoder.textures[4], let depthT = encoder.textures[5],
              let resultT = encoder.textures[6] else {
            throw NSError(domain: "Compositor.VolumetricLightCompute", code: 4)
        }
        let p = loadParams(data)
        let w = resultT.width, h = resultT.height
        let image = try pixels(imageT)
        let beams = try pixels(beamsT)
        let near = try pixels(nearT)
        let glows = try pixels(glowsT)
        let ambient = try pixels(ambientT)
        let depth = try pixels(depthT)
        let iw = imageT.width, ih = imageT.height
        let bw = beamsT.width, bh = beamsT.height
        let nw = nearT.width, nh = nearT.height
        let gw = glowsT.width, gh = glowsT.height
        let aw = ambientT.width, ah = ambientT.height
        let dw = depthT.width, dh = depthT.height
        var result = image
        for y in 0..<h {
            for x in 0..<w {
                func at(_ input: Int) -> (Int, Int) {
                    let o = p.offsets[input]
                    return (x + Int(o.x.rounded(.towardZero)), y + Int(o.y.rounded(.towardZero)))
                }
                let (ix, iy) = at(0)
                let color = texel(image, iw, ih, ix, iy)
                let i = (y * w + x) * 4
                if color.w <= 0 {
                    result[i] = color.x; result[i + 1] = color.y; result[i + 2] = color.z; result[i + 3] = color.w
                    continue
                }
                let (bx, by) = at(1)
                let (nx, ny) = at(2)
                let (gx, gy) = at(3)
                let (ax, ay) = at(4)
                let (dx, dy) = at(5)
                let gathered = texel(beams, bw, bh, bx, by).x
                let front = min(1, max(0, texel(near, nw, nh, nx, ny).x))
                let bloom = max3(SIMD3<Float>(repeating: 0), SIMD3(texel(glows, gw, gh, gx, gy).x,
                                      texel(glows, gw, gh, gx, gy).y,
                                      texel(glows, gw, gh, gx, gy).z))
                let air = max3(SIMD3<Float>(repeating: 0), SIMD3(texel(ambient, aw, ah, ax, ay).x,
                                    texel(ambient, aw, ah, ax, ay).y,
                                    texel(ambient, aw, ah, ax, ay).z))
                let far: Float
                if p.hasDepth > 0.5 {
                    far = 1 - min(1, max(0, texel(depth, dw, dh, dx, dy).x))
                } else {
                    let down = (p.top + Float(y) + 0.5) / max(1, p.height)
                    far = (1 - smoothstep(0.45, 1.05, down)) * (1 - 0.8 * front)
                }
                let glow = exp(-length(SIMD2(Float(x) + 0.5, Float(y) + 0.5) - p.light) / (p.side * 0.35))
                let ramp = smoothstep(p.start, p.end, far)
                let fog = 1 - exp(-3 * p.haze * (0.12 + 0.88 * ramp))
                let fogColor = air * mix3(SIMD3(repeating: 1), p.tint, 0.6) * 0.9 + p.tint * glow * 0.45
                let base = max3(SIMD3<Float>(repeating: 0), SIMD3(color.x, color.y, color.z) / color.w)
                let veiled = mix3(base, fogColor, fog) + bloom * p.haze * 1.6 * (0.3 + 0.7 * ramp)
                let added = p.color * gathered * 0.5 * (1 - 0.92 * front)
                let capped = min3(veiled, SIMD3(repeating: 1))
                var lit = SIMD3(
                    1 - (1 - capped.x) * exp(-added.x),
                    1 - (1 - capped.y) * exp(-added.y),
                    1 - (1 - capped.z) * exp(-added.z)
                )
                lit = max3(lit, veiled + (lit - capped))
                result[i] = lit.x * color.w
                result[i + 1] = lit.y * color.w
                result[i + 2] = lit.z * color.w
                result[i + 3] = color.w
            }
        }
        store(result, into: resultT)
    }
}
