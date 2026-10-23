// CoreFoundationTypes.swift — the toll-free-bridged CoreFoundation names upstream code writes explicitly
// (`colors as CFArray`, `[kCGImageSourceShouldCache: true] as CFDictionary`). On Linux they resolve to the
// Swift value types they bridge to on Apple platforms, so the same `as` casts compile unchanged.

import Foundation

public typealias CFArray = [Any]
public typealias CFDictionary = [AnyHashable: Any]
public typealias CFString = String
public typealias CFURL = URL
public typealias CFData = Data
public typealias CFMutableData = NSMutableData
public typealias CFTypeRef = AnyObject

public func CFDataGetBytePtr(_ data: CFData) -> UnsafePointer<UInt8>? {
    // Apple toll-free CFData keeps this pointer for `data`'s lifetime. Here CFData is Data:
    // `(data as NSData).bytes` is wrong on Linux (probe: not the Data's buffer). Contiguous
    // `withUnsafeBytes` points into Data's own storage; valid while the caller's Data binding
    // lives and is not mutated — enough for BrushRaster.copy's guard-scoped use.
    data.withUnsafeBytes { $0.baseAddress?.assumingMemoryBound(to: UInt8.self) }
}

public func CFDataGetLength(_ data: CFData) -> Int { data.count }
