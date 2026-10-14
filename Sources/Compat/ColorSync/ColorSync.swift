// ColorSync — the profile calls upstream makes (CMYK.swift), over LittleCMS 2.
//
// Upstream names a CMYK profile by its ICC description. macOS's own Generic CMYK profile describes itself as
// "Generic CMYK Profile"; on Linux that role is played by the profile installed as `Generic CMYK Profile.icc` in the
// app's CMYK profile folder by the user, so those bytes are described by that name. It is not Apple's profile.

import Foundation
import CompositorColorManagement

/// An ICC profile (Apple: `ColorSyncProfileRef`).
public final class ColorSyncProfile {
    public let data: Data
    init(data: Data) { self.data = data }
}

/// What ColorSync's Create/Copy functions return; `takeRetainedValue()` hands over the value, as with Core Foundation.
public struct ColorSyncRetained<Value> {
    let value: Value
    public func takeRetainedValue() -> Value { value }
    public func takeUnretainedValue() -> Value { value }
}

/// The profile in `data`, or nil when it isn't one. Errors are not reported (upstream passes nil).
public func ColorSyncProfileCreate(_ data: Data, _ error: UnsafeMutableRawPointer?) -> ColorSyncRetained<ColorSyncProfile>? {
    let model = data.withUnsafeBytes { bytes in
        compositor_icc_color_model(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
    }
    guard Int(model) != Int(COMPOSITOR_ICC_UNKNOWN) else { return nil }
    return ColorSyncRetained(value: ColorSyncProfile(data: data))
}

/// The profile's description, in English where it has one.
public func ColorSyncProfileCopyDescriptionString(_ profile: ColorSyncProfile) -> ColorSyncRetained<String>? {
    if ColorSyncGenericProfiles.isGenericCMYK(profile.data) { return ColorSyncRetained(value: ColorSyncGenericProfiles.genericCMYKName) }
    let length = profile.data.withUnsafeBytes { bytes in
        compositor_icc_description(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, nil, 0)
    }
    guard length >= 0 else { return nil }
    var text = [CChar](repeating: 0, count: Int(length) + 1)
    _ = profile.data.withUnsafeBytes { bytes in
        compositor_icc_description(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &text, text.count)
    }
    return ColorSyncRetained(value: String(cString: text))
}

/// The platform's generic profiles, as macOS keeps them in /System/Library/ColorSync/Profiles.
public enum ColorSyncGenericProfiles {
    public static let genericCMYKName = "Generic CMYK Profile"
    /// Where Linux keeps CMYK profiles: upstream's own Load Profile folder (Application Support/CMYK Profiles).
    public static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CMYK Profiles", isDirectory: true)
    }
    public static var genericCMYKFile: URL { folder.appendingPathComponent(genericCMYKName + ".icc") }

    nonisolated(unsafe) private static var known: (modified: Date, data: Data)?
    private static let lock = NSLock()
    /// Whether `data` is the installed Generic CMYK profile.
    public static func isGenericCMYK(_ data: Data) -> Bool {
        let file = genericCMYKFile
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return false }
        lock.lock(); defer { lock.unlock() }
        if known?.modified != modified { known = (try? Data(contentsOf: file)).map { (modified, $0) } }
        return known?.data == data
    }
}
