import Foundation
import Glibc

/// Dynamically loaded PDF engine. The Core Graphics API owns page geometry; the backend only parses and rasterizes.
final class NativePDFDocument: @unchecked Sendable {
    private struct API {
        typealias Open = @convention(c) (UnsafePointer<UInt8>?, Int) -> UnsafeMutableRawPointer?
        typealias Close = @convention(c) (UnsafeMutableRawPointer?) -> Void
        typealias Count = @convention(c) (UnsafeMutableRawPointer?) -> Int32
        typealias Page = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Double>?,
                                       UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Int32>?) -> Int32
        typealias Render = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32) -> UnsafeMutablePointer<UInt8>?
        let open: Open, close: Close, count: Count, locked: Count, page: Page, render: Render
    }
    private static let api: API? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [ProcessInfo.processInfo.environment["COMPOSITOR_PDF_BACKEND"] ?? "",
                          "libCompositorPDFBackend.so", "/app/lib/libCompositorPDFBackend.so",
                          root.appendingPathComponent(".build/linux-contract-native/libCompositorPDFBackend.so").path]
        for path in candidates where !path.isEmpty {
            guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            guard let open = dlsym(library, "compositor_pdf_open"), let close = dlsym(library, "compositor_pdf_close"),
                  let count = dlsym(library, "compositor_pdf_count"), let locked = dlsym(library, "compositor_pdf_locked"),
                  let page = dlsym(library, "compositor_pdf_page"), let render = dlsym(library, "compositor_pdf_render") else {
                dlclose(library); continue
            }
            return API(open: unsafeBitCast(open, to: API.Open.self), close: unsafeBitCast(close, to: API.Close.self),
                       count: unsafeBitCast(count, to: API.Count.self), locked: unsafeBitCast(locked, to: API.Count.self),
                       page: unsafeBitCast(page, to: API.Page.self), render: unsafeBitCast(render, to: API.Render.self))
        }
        return nil
    }()
    private let handle: UnsafeMutableRawPointer
    static var isAvailable: Bool { api != nil }
    private let engine: API
    private let lock = NSLock()
    let count: Int
    let isLocked: Bool
    init?(_ bytes: [UInt8]) {
        guard let engine = Self.api, let handle = bytes.withUnsafeBufferPointer({ engine.open($0.baseAddress, $0.count) }) else { return nil }
        self.engine = engine; self.handle = handle
        count = Int(engine.count(handle)); isLocked = engine.locked(handle) != 0
    }
    deinit { engine.close(handle) }
    func page(_ index: Int) -> (box: CGRect, rotation: Int32)? {
        lock.lock(); defer { lock.unlock() }
        var width = 0.0, height = 0.0, rotation: Int32 = 0
        guard index >= 0, index < count, engine.page(handle, Int32(index), &width, &height, &rotation) == 0,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return (CGRect(x: 0, y: 0, width: width, height: height), rotation)
    }
    func render(_ index: Int, width: Int, height: Int) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard (1...32768).contains(width), (1...32768).contains(height),
              width * height <= 512_000_000,
              let pixels = engine.render(handle, Int32(index), Int32(width), Int32(height)) else { return nil }
        defer { free(pixels) }
        return CGImage(PortableImage(width: width, height: height, kind: .rgba, bytesPerRow: width * 4,
                                    bytes: Array(UnsafeBufferPointer(start: pixels, count: width * height * 4))))
    }
}
