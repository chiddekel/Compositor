// ColorSync — the profile calls upstream makes (CMYK.swift), over LittleCMS 2.
//
// Upstream names a CMYK profile by its ICC description. macOS's own Generic CMYK profile describes itself as
// "Generic CMYK Profile"; on Linux that role is played by the profile installed as `Generic CMYK Profile.icc` in the
// app's CMYK profile folder, so those bytes are described by that name. It is not Apple's profile: on first run the app
// installs a redistributable one there (third_party/color, SWOP TR005 Coated, CC0), and a user may replace it.

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

    /// The redistributable stand-in for Apple's Generic CMYK: COMPOSITOR_CMYK_PROFILE, the Flatpak's copy, or the
    /// source tree's (`third_party/color`, found above this file).
    public static var bundledDefault: URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var checkout: String?
        while directory.path != "/" {
            let file = directory.appendingPathComponent("third_party/color/SWOP_TR005_coated_5.icc").path
            if FileManager.default.fileExists(atPath: file) { checkout = file; break }
            directory = directory.deletingLastPathComponent()
        }
        let candidates: [String?] = [ProcessInfo.processInfo.environment["COMPOSITOR_CMYK_PROFILE"],
                                     "/app/share/compositor/color/SWOP_TR005_coated_5.icc", checkout]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// Gives a fresh install the Generic CMYK profile macOS always has, so View › CMYK and CMYK export work before the
    /// user loads one (upstream picks "Generic CMYK Profile" when nothing is chosen). A profile already there — the
    /// user's own, or an earlier copy — is kept. Returns whether one is there afterwards.
    @discardableResult public static func installBundledDefault() -> Bool {
        let file = genericCMYKFile
        if FileManager.default.fileExists(atPath: file.path) { return true }
        guard let source = bundledDefault, let data = try? Data(contentsOf: source) else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

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
