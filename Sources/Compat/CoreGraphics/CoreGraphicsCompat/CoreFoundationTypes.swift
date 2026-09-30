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
    // Apple: toll-free CFData keeps this pointer valid for `data`'s lifetime. Here CFData is Data,
    // and `(data as NSData).bytes` dangles when that temporary NSData is released at end-of-statement.
    // Call sites must use `data.withUnsafeBytes` (see BrushRaster.copy) instead of this helper.
    data.withUnsafeBytes { $0.baseAddress?.assumingMemoryBound(to: UInt8.self) }
}

public func CFDataGetLength(_ data: CFData) -> Int { data.count }
