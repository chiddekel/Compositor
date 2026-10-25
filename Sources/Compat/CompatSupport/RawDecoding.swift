// RawDecoding.swift — camera RAW decoding for the compat ImageIO (size probes) and CoreImage (`CIRAWFilter`), from the
// host's LibRaw-backed decoder (host/RawDecoder.cpp), registered at startup through `compositor_raw_register`.
//
// RAW files can be hundreds of megabytes, so: a size probe reads only the header; a file is unpacked once into a
// `RawDecoding.Handle` that filters for the same file share (and that survives the brief gap between upstream's
// as-shot probe and its preview filter); developing never re-reads the file. Without a registered decoder every
// entry point reports "unavailable" and RAW files stay unreadable, as before.

import Foundation

public enum RawDecoding {
    public typealias ProbeFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    public typealias OpenFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                              UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?) -> OpaquePointer?
    public typealias DevelopFn = @convention(c) (OpaquePointer?, Float, Float, Float, Float, Float, Int32, Int32, Float, Int32,
                                                 UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                                                 UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    public typealias Develop16Fn = @convention(c) (OpaquePointer?, Float, Float, Float, Float, Float, Int32, Int32, Float, Int32,
                                                  UnsafeMutablePointer<UnsafeMutablePointer<UInt16>?>?,
                                                  UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    public typealias CapabilitiesFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt32>?,
        UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    public struct Capabilities: Sendable {
        public let flags: UInt32
        public let noiseReduction: Float
        public let lensCorrection: Bool, highlightRecovery: Bool
        public var supportsNoiseReduction: Bool { flags & 1 != 0 }
        public var supportsLensCorrection: Bool { flags & 2 != 0 }
        public var supportsHighlightRecovery: Bool { flags & 4 != 0 }
    }
    nonisolated(unsafe) static var capabilitiesFn: CapabilitiesFn?
    public typealias CloseFn = @convention(c) (OpaquePointer?) -> Void

    nonisolated(unsafe) static var probeFn: ProbeFn?
    nonisolated(unsafe) static var openFn: OpenFn?
    nonisolated(unsafe) static var developFn: DevelopFn?
    nonisolated(unsafe) static var develop16Fn: Develop16Fn?
    nonisolated(unsafe) static var closeFn: CloseFn?

    public static var isAvailable: Bool { openFn != nil }

    /// Camera RAW extensions LibRaw reads (the common ones; DNG included).
    public static let extensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "raf", "rw2", "rwl", "pef", "ptx", "srw",
        "x3f", "3fr", "fff", "iiq", "erf", "kdc", "dcr", "mos", "mef", "mrw", "raw", "gpr",
    ]
    public static func isRaw(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Developed (oriented) size from the header alone.
    public static func probe(_ url: URL) -> (width: Int, height: Int)? {
        guard let probeFn else { return nil }
        var w: Int32 = 0, h: Int32 = 0
        let status = url.path.withCString { probeFn($0, &w, &h) }
        return status == 0 && w > 0 && h > 0 ? (Int(w), Int(h)) : nil
    }

    /// A file unpacked once; developed any number of times.
    public final class Handle: @unchecked Sendable {
        fileprivate let raw: OpaquePointer
        public let path: String
        public let width: Int, height: Int
        public let asShotTemperature: Float, asShotTint: Float
        public let capabilities: Capabilities
        /// A full-resolution develop has been made: the import is done, so it isn't kept around afterwards.
        fileprivate var consumed = false
        private let lock = NSLock()
        private let close: CloseFn?
        private let decode8: DevelopFn?
        private let decode16: Develop16Fn?
        public var supportsSixteenBit: Bool { decode16 != nil }

        fileprivate init(raw: OpaquePointer, path: String, width: Int, height: Int, temperature: Float, tint: Float) {
            close = RawDecoding.closeFn
            decode8 = RawDecoding.developFn
            decode16 = RawDecoding.develop16Fn
            self.raw = raw; self.path = path; self.width = width; self.height = height
            asShotTemperature = temperature; asShotTint = tint
            var flags: UInt32 = 0, noise: Float = 0
            var lens: Int32 = 0, highlight: Int32 = 0
            if RawDecoding.capabilitiesFn?(raw, &flags, &noise, &lens, &highlight) != 0 {
                flags = 0; noise = 0; lens = 0; highlight = 0
            }
            capabilities = Capabilities(flags: flags, noiseReduction: noise, lensCorrection: lens != 0, highlightRecovery: highlight != 0)
        }
        deinit { close?(raw) }

        /// Premultiplied RGBA8, `scale` of the full size; `draft` allows the half-size fast path.
        public func develop(exposure: Float, temperature: Float, tint: Float, boost: Float, scale: Float, draft: Bool,
                            noiseReduction: Float = 0, lensCorrection: Bool = false, highlightRecovery: Bool = false)
            -> (bytes: [UInt8], width: Int, height: Int)? {
            guard let developFn = decode8 else { return nil }
            lock.lock(); defer { lock.unlock() }   // one develop at a time per handle (LibRaw keeps state)
            var pixels: UnsafeMutablePointer<UInt8>?
            var w: Int32 = 0, h: Int32 = 0
            let noise = capabilities.supportsNoiseReduction && noiseReduction.isFinite ? min(1, max(0, noiseReduction)) : capabilities.noiseReduction
            let lens = capabilities.supportsLensCorrection ? lensCorrection : capabilities.lensCorrection
            let highlight = capabilities.supportsHighlightRecovery ? highlightRecovery : capabilities.highlightRecovery
            let status = developFn(raw, exposure, temperature, tint, boost, noise, lens ? 1 : 0, highlight ? 1 : 0,
                                   scale, draft ? 1 : 0, &pixels, &w, &h)
            guard status == 0, let pixels, w > 0, h > 0 else { return nil }
            defer { free(pixels) }
            if scale >= 1, !draft { consumed = true }
            return (Array(UnsafeBufferPointer(start: pixels, count: Int(w) * Int(h) * 4)), Int(w), Int(h))
        }

        /// Opaque native-endian RGBA16. Data owns the decoder's allocation, avoiding a full-frame copy.
        public func develop16(exposure: Float, temperature: Float, tint: Float, boost: Float, scale: Float, draft: Bool,
                              noiseReduction: Float = 0, lensCorrection: Bool = false, highlightRecovery: Bool = false)
            -> (data: Data, width: Int, height: Int)? {
            guard let decode16 else { return nil }
            lock.lock(); defer { lock.unlock() }
            var pixels: UnsafeMutablePointer<UInt16>?
            var w: Int32 = 0, h: Int32 = 0
            let noise = capabilities.supportsNoiseReduction && noiseReduction.isFinite ? min(1, max(0, noiseReduction)) : capabilities.noiseReduction
            let lens = capabilities.supportsLensCorrection ? lensCorrection : capabilities.lensCorrection
            let highlight = capabilities.supportsHighlightRecovery ? highlightRecovery : capabilities.highlightRecovery
            let status = decode16(raw, exposure, temperature, tint, boost, noise, lens ? 1 : 0, highlight ? 1 : 0,
                                  scale, draft ? 1 : 0, &pixels, &w, &h)
            guard status == 0, let pixels else { return nil }
            let (area, areaOverflow) = Int(w).multipliedReportingOverflow(by: Int(h))
            let (bytes, bytesOverflow) = area.multipliedReportingOverflow(by: 8)
            guard w > 0, h > 0, !areaOverflow, !bytesOverflow else { free(pixels); return nil }
            if scale >= 1, !draft { consumed = true }
            return (Data(bytesNoCopy: UnsafeMutableRawPointer(pixels), count: bytes, deallocator: .free), Int(w), Int(h))
        }
    }

    // Filters alive at once share a handle (weak); the most recent one is also held briefly (strong) so upstream's
    // open-close-open sequence (as-shot probe, then the preview filter) unpacks once.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: [String: WeakHandle] = [:]
    nonisolated(unsafe) private static var recent: Handle?
    private final class WeakHandle { weak var handle: Handle?; init(_ h: Handle) { handle = h } }

    public static func open(_ url: URL) -> Handle? {
        guard let openFn else { return nil }
        let path = url.standardizedFileURL.path
        lock.lock()
        if let shared = live[path]?.handle, !shared.consumed { lock.unlock(); return shared }
        if let kept = recent, kept.path == path, !kept.consumed { lock.unlock(); return kept }
        lock.unlock()
        var w: Int32 = 0, h: Int32 = 0
        var temperature: Float = 5000, tint: Float = 0
        guard let raw = path.withCString({ openFn($0, &w, &h, &temperature, &tint) }) else { return nil }
        let handle = Handle(raw: raw, path: path, width: Int(w), height: Int(h), temperature: temperature, tint: tint)
        lock.lock()
        live[path] = WeakHandle(handle)
        recent = handle   // a different file replaces it, freeing the previous one's memory
        lock.unlock()
        return handle
    }

    /// Drops the brief keep-alive once a handle is no longer wanted (a finished full develop).
    public static func releaseIfConsumed(_ handle: Handle) {
        lock.lock(); defer { lock.unlock() }
        if handle.consumed, recent === handle { recent = nil }
    }
}

@_cdecl("compositor_raw_register")
public func compositor_raw_register(_ probe: RawDecoding.ProbeFn?, _ open: RawDecoding.OpenFn?,
                                    _ develop: RawDecoding.DevelopFn?, _ close: RawDecoding.CloseFn?, _ capabilities: RawDecoding.CapabilitiesFn?) {
    compositor_raw_register_v2(probe, open, develop, close, capabilities, nil)
}

@_cdecl("compositor_raw_register_v2")
public func compositor_raw_register_v2(_ probe: RawDecoding.ProbeFn?, _ open: RawDecoding.OpenFn?,
                                       _ develop: RawDecoding.DevelopFn?, _ close: RawDecoding.CloseFn?,
                                       _ capabilities: RawDecoding.CapabilitiesFn?, _ develop16: RawDecoding.Develop16Fn?) {
    RawDecoding.probeFn = probe
    RawDecoding.openFn = open
    RawDecoding.developFn = develop
    RawDecoding.develop16Fn = develop16
    RawDecoding.closeFn = close
    RawDecoding.capabilitiesFn = capabilities
}
