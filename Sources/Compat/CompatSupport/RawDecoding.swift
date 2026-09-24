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
    public typealias DevelopFn = @convention(c) (OpaquePointer?, Float, Float, Float, Float, Float, Int32,
                                                 UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                                                 UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    public typealias CloseFn = @convention(c) (OpaquePointer?) -> Void

    nonisolated(unsafe) static var probeFn: ProbeFn?
    nonisolated(unsafe) static var openFn: OpenFn?
    nonisolated(unsafe) static var developFn: DevelopFn?
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
        /// A full-resolution develop has been made: the import is done, so it isn't kept around afterwards.
        fileprivate var consumed = false
        private let lock = NSLock()

        fileprivate init(raw: OpaquePointer, path: String, width: Int, height: Int, temperature: Float, tint: Float) {
            self.raw = raw; self.path = path; self.width = width; self.height = height
            asShotTemperature = temperature; asShotTint = tint
        }
        deinit { RawDecoding.closeFn?(raw) }

        /// Premultiplied RGBA8, `scale` of the full size; `draft` allows the half-size fast path.
        public func develop(exposure: Float, temperature: Float, tint: Float, boost: Float, scale: Float, draft: Bool)
            -> (bytes: [UInt8], width: Int, height: Int)? {
            guard let developFn = RawDecoding.developFn else { return nil }
            lock.lock(); defer { lock.unlock() }   // one develop at a time per handle (LibRaw keeps state)
            var pixels: UnsafeMutablePointer<UInt8>?
            var w: Int32 = 0, h: Int32 = 0
            let status = developFn(raw, exposure, temperature, tint, boost, scale, draft ? 1 : 0, &pixels, &w, &h)
            guard status == 0, let pixels, w > 0, h > 0 else { return nil }
            defer { free(pixels) }
            if scale >= 1, !draft { consumed = true }
            return (Array(UnsafeBufferPointer(start: pixels, count: Int(w) * Int(h) * 4)), Int(w), Int(h))
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
                                    _ develop: RawDecoding.DevelopFn?, _ close: RawDecoding.CloseFn?) {
    RawDecoding.probeFn = probe
    RawDecoding.openFn = open
    RawDecoding.developFn = develop
    RawDecoding.closeFn = close
}
