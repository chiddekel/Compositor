// Apple's `simd` module is not part of the Linux Swift SDK. Tip MetalRimLight / MetalVolumetricLight only need
// SIMD types (Swift stdlib) plus a few vector helpers; this target supplies that module name and those helpers.

public func simd_dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a * b).sum() }
public func simd_dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
public func simd_dot(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { (a * b).sum() }

public func simd_length(_ v: SIMD2<Float>) -> Float { (v * v).sum().squareRoot() }
public func simd_length(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }
public func simd_length(_ v: SIMD4<Float>) -> Float { (v * v).sum().squareRoot() }

public func simd_normalize(_ v: SIMD2<Float>) -> SIMD2<Float> {
    let len = simd_length(v)
    return len > 1e-8 ? v / len : .zero
}
public func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let len = simd_length(v)
    return len > 1e-8 ? v / len : .zero
}
public func simd_normalize(_ v: SIMD4<Float>) -> SIMD4<Float> {
    let len = simd_length(v)
    return len > 1e-8 ? v / len : .zero
}

public func simd_min(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(min(a.x, b.x), min(a.y, b.y), min(a.z, b.z))
}
public func simd_max(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(max(a.x, b.x), max(a.y, b.y), max(a.z, b.z))
}
