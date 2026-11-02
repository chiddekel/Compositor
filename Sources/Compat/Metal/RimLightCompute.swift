import Foundation

/// CPU execution of tip `MetalRimLight` kernels (`rimLight`, `rimCombine`). Float textures keep HDR coverage.
enum RimLightCompute {

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
        let combine = encoder.pipeline?.name == "rimCombine"
        guard encoder.ended, let data = encoder.bytes[0], data.count >= 112 else {
            throw NSError(domain: "Compositor.RimLightCompute", code: 1)
        }
        if combine {
            try runCombine(encoder, data: data)
        } else {
            try runLight(encoder, data: data)
        }
    }

    // MARK: - Parameter layout (matches tip MetalRimLight.Parameters / Metal float4 packing)

    private struct Params {
        var direction: SIMD3<Float>
        var color: SIMD3<Float>
        var offsets: [SIMD2<Float>] // 8 inputs
        var width: Float
        var reach: Float
        var detailScale: Float
        var choke: Float
    }

    private static func loadParams(_ data: Data) -> Params {
        func f(_ offset: Int) -> Float {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
        }
        var offsets = [SIMD2<Float>](repeating: .zero, count: 8)
        for i in 0..<8 {
            let base = 32 + (i / 2) * 16 + (i % 2) * 8
            offsets[i] = SIMD2(f(base), f(base + 4))
        }
        return Params(
            direction: SIMD3(f(0), f(4), f(8)),
            color: SIMD3(f(16), f(20), f(24)),
            offsets: offsets,
            width: f(96), reach: f(100), detailScale: f(104), choke: f(108)
        )
    }

    // MARK: - Texture helpers

    private static func pixels(_ texture: MTLTexture) throws -> [Float] {
        guard texture.width > 0, texture.height > 0,
              [.rgba16Float, .rgba32Float].contains(texture.pixelFormat),
              texture.rgbaBytes.count == texture.width * texture.height * texture.bytesPerPixel else {
            throw NSError(domain: "Compositor.RimLightCompute", code: 2)
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

    private static func readR(_ px: [Float], _ w: Int, _ h: Int, _ x: Int, _ y: Int) -> Float {
        texel(px, w, h, x, y).x
    }

    private static func inwardsIn(_ px: [Float], _ w: Int, _ h: Int, _ x: Int, _ y: Int) -> SIMD2<Float> {
        let d = SIMD2(
            readR(px, w, h, x + 1, y) - readR(px, w, h, x - 1, y),
            readR(px, w, h, x, y - 1) - readR(px, w, h, x, y + 1)
        )
        let len = length(d)
        return len > 1e-6 ? d / len : .zero
    }

    /// Giles inverse-error-function approximation (same coefficients as tip Metal).
    private static func inverseError(_ x: Float) -> Float {
        var w = -log((1 - x) * (1 + x)), p: Float
        if w < 5 {
            w -= 2.5
            p = 2.81022636e-08
            p = 3.43273939e-07 + p * w
            p = -3.5233877e-06 + p * w
            p = -4.39150654e-06 + p * w
            p = 0.00021858087 + p * w
            p = -0.00125372503 + p * w
            p = -0.00417768164 + p * w
            p = 0.246640727 + p * w
            p = 1.50140941 + p * w
        } else {
            w = sqrt(w) - 3
            p = -0.000200214257
            p = 0.000100950558 + p * w
            p = 0.00134934322 + p * w
            p = -0.00367342844 + p * w
            p = 0.00573950773 + p * w
            p = -0.0076224613 + p * w
            p = 0.00943887047 + p * w
            p = 1.00167406 + p * w
            p = 2.83297682 + p * w
        }
        return p * x
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - edge0) / max(1e-8, edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Kernels

    private static func runLight(_ encoder: MTLComputeCommandEncoder, data: Data) throws {
        guard let imageT = encoder.textures[0], let coverageT = encoder.textures[1],
              let outlineT = encoder.textures[2], let fineT = encoder.textures[3],
              let coarseT = encoder.textures[4], let backdropT = encoder.textures[5],
              let nearT = encoder.textures[6], let busyT = encoder.textures[7],
              let resultT = encoder.textures[8] else {
            throw NSError(domain: "Compositor.RimLightCompute", code: 3)
        }
        let p = loadParams(data)
        let w = resultT.width, h = resultT.height
        guard imageT.width == w, imageT.height == h else {
            throw NSError(domain: "Compositor.RimLightCompute", code: 4)
        }
        let image = try pixels(imageT)
        let coverage = try pixels(coverageT)
        let outline = try pixels(outlineT)
        let fine = try pixels(fineT)
        let coarse = try pixels(coarseT)
        let backdrop = try pixels(backdropT)
        let near = try pixels(nearT)
        let busy = try pixels(busyT)
        let iw = imageT.width, ih = imageT.height
        let cw = coverageT.width, ch = coverageT.height
        let ow = outlineT.width, oh = outlineT.height
        let fw = fineT.width, fh = fineT.height
        let kw = coarseT.width, kh = coarseT.height
        let bw = backdropT.width, bh = backdropT.height
        let nw = nearT.width, nh = nearT.height
        let vw = busyT.width, vh = busyT.height

        func at(_ input: Int, _ x: Int, _ y: Int) -> (Int, Int) {
            let o = p.offsets[input]
            return (x + Int(o.x.rounded(.towardZero)), y + Int(o.y.rounded(.towardZero)))
        }

        var result = [Float](repeating: 0, count: w * h * 4)
        let direction = normalize(p.direction)
        for y in 0..<h {
            for x in 0..<w {
                let (ix, iy) = at(0, x, y)
                let (cx, cy) = at(1, x, y)
                let (ox, oy) = at(2, x, y)
                let (fx, fy) = at(3, x, y)
                let (kx, ky) = at(4, x, y)
                let (bx, by) = at(5, x, y)
                let (nx, ny) = at(6, x, y)
                let (vx, vy) = at(7, x, y)
                let covered = readR(coverage, cw, ch, cx, cy)
                let closeness = readR(near, nw, nh, nx, ny)
                if covered <= 0.002 && closeness <= 0.002 { continue }
                let color = texel(image, iw, ih, ix, iy)
                let albedo = color.w > 0
                    ? max3(SIMD3<Float>(repeating: 0), SIMD3(color.x, color.y, color.z) / color.w)
                    : .zero
                let tint = p.color * (albedo * 0.7 + SIMD3(repeating: 0.45))

                let level = min(0.999, max(0.001, readR(outline, ow, oh, ox, oy)))
                let depth = p.reach * sqrt(2) * inverseError(2 * level - 1)
                let inwards = inwardsIn(outline, ow, oh, ox, oy)
                let bumps = SIMD2(
                    (readR(fine, fw, fh, fx + 1, fy) - readR(coarse, kw, kh, kx + 1, ky))
                        - (readR(fine, fw, fh, fx - 1, fy) - readR(coarse, kw, kh, kx - 1, ky)),
                    (readR(fine, fw, fh, fx, fy - 1) - readR(coarse, kw, kh, kx, ky - 1))
                        - (readR(fine, fw, fh, fx, fy + 1) - readR(coarse, kw, kh, kx, ky + 1))
                ) / 2
                var surface = SIMD3(-inwards.x * 2.75 - bumps.x * p.detailScale,
                                    -inwards.y * 2.75 - bumps.y * p.detailScale, 1)
                surface = normalize(surface)
                let lit = pow(max(0, dot(surface, direction)), 1.6)
                let t = max(depth, 0) / max(1e-6, p.width)
                let held = 1 - smoothstep(max(0, (p.choke - 0.3) / 0.7) * 0.95, 1, t)
                let tail = exp(-2.2 * t)
                let reaches = (p.choke < 0.3 ? mix(tail, held, p.choke / 0.3) : held) * (1 - smoothstep(1.5, 1.9, t))
                let texture = readR(fine, fw, fh, fx, fy) - readR(coarse, kw, kh, kx, ky)
                let catches = min(1.8, max(0.3, 1 + texture * 6))
                let inside = smoothstep(-1.5, 1.5, depth)
                var added = tint * lit * reaches * catches * covered * inside

                let apart = texel(backdrop, bw, bh, bx, by)
                let spread = texel(busy, vw, vh, vx, vy)
                let differs: Float = (apart.x.isFinite && apart.y.isFinite && apart.z.isFinite)
                    ? max(apart.x, max(apart.y, apart.z)) : 0
                let varies: Float = (spread.x.isFinite && spread.y.isFinite && spread.z.isFinite)
                    ? sqrt(max(0, max(spread.x, max(spread.y, spread.z)))) : 1
                let strand = min(1, max(0, (differs - 0.03 - 2.5 * varies) / 0.1))
                    * smoothstep(0, 0.1, closeness) * (1 - inside)
                if strand > 0 {
                    let away = inwardsIn(near, nw, nh, nx, ny)
                    var faceN = SIMD3(-away.x * 2.75, -away.y * 2.75, 1)
                    faceN = normalize(faceN)
                    let faces = pow(max(0, dot(faceN, direction)), 1.6)
                    added += tint * faces * strand
                }
                let i = (y * w + x) * 4
                result[i] = added.x * color.w
                result[i + 1] = added.y * color.w
                result[i + 2] = added.z * color.w
                result[i + 3] = 0
            }
        }
        store(result, into: resultT)
    }

    private static func runCombine(_ encoder: MTLComputeCommandEncoder, data: Data) throws {
        guard let imageT = encoder.textures[0], let lightT = encoder.textures[1],
              let resultT = encoder.textures[2] else {
            throw NSError(domain: "Compositor.RimLightCompute", code: 5)
        }
        let p = loadParams(data)
        let w = resultT.width, h = resultT.height
        let image = try pixels(imageT)
        let light = try pixels(lightT)
        let iw = imageT.width, ih = imageT.height
        let lw = lightT.width, lh = lightT.height
        var result = image
        for y in 0..<h {
            for x in 0..<w {
                let ix = x + Int(p.offsets[0].x.rounded(.towardZero))
                let iy = y + Int(p.offsets[0].y.rounded(.towardZero))
                let lx = x + Int(p.offsets[1].x.rounded(.towardZero))
                let ly = y + Int(p.offsets[1].y.rounded(.towardZero))
                let color = texel(image, iw, ih, ix, iy)
                let i = (y * w + x) * 4
                if color.w <= 0 {
                    result[i] = color.x; result[i + 1] = color.y; result[i + 2] = color.z; result[i + 3] = color.w
                    continue
                }
                let added = max3(SIMD3<Float>(repeating: 0), SIMD3(texel(light, lw, lh, lx, ly).x,
                                      texel(light, lw, lh, lx, ly).y,
                                      texel(light, lw, lh, lx, ly).z))
                let base = SIMD3(
                    min(1, max(0, color.x / color.w)),
                    min(1, max(0, color.y / color.w)),
                    min(1, max(0, color.z / color.w))
                )
                let eased = SIMD3(1 - exp(-added.x), 1 - exp(-added.y), 1 - exp(-added.z))
                let lit = SIMD3(
                    (1 - (1 - base.x) * (1 - eased.x)) * color.w,
                    (1 - (1 - base.y) * (1 - eased.y)) * color.w,
                    (1 - (1 - base.z) * (1 - eased.z)) * color.w
                )
                result[i] = lit.x; result[i + 1] = lit.y; result[i + 2] = lit.z; result[i + 3] = color.w
            }
        }
        store(result, into: resultT)
    }

    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
}
