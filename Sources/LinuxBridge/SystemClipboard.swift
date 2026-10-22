// The desktop clipboard behind NSPasteboard.general: the Qt shell hands its QClipboard over as C functions, so
// upstream's copy and paste (SelectionClipboard, NewCanvasSheet's clipboard size) reach other applications as they do
// on macOS. Types travel as Apple's identifiers (public.png, public.utf8-plain-text, ...); the shell maps them to MIME.
import AppKit
import Foundation

public typealias ClipboardWriteFn = @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<UnsafePointer<UInt8>?>?,
                                                    UnsafePointer<Int>?) -> Void
public typealias ClipboardTypesFn = @convention(c) (UnsafeMutablePointer<CChar>?, Int) -> Int64
public typealias ClipboardReadFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<UInt8>?, Int) -> Int64
public typealias ClipboardChangesFn = @convention(c) () -> Int64

final class SystemClipboard: NSPasteboard.Backend {
    let writeFn: ClipboardWriteFn, typesFn: ClipboardTypesFn, readFn: ClipboardReadFn, changesFn: ClipboardChangesFn
    init(write: ClipboardWriteFn, types: ClipboardTypesFn, read: ClipboardReadFn, changes: ClipboardChangesFn) {
        writeFn = write; typesFn = types; readFn = read; changesFn = changes
    }
    func write(_ items: [NSPasteboard.PasteboardType: Data]) {
        let entries = Array(items)
        let names = entries.map { strdup($0.key.rawValue) }
        defer { names.forEach { free($0) } }
        let copies = entries.map { entry -> UnsafeMutablePointer<UInt8> in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, entry.value.count))
            entry.value.copyBytes(to: buffer, count: entry.value.count)
            return buffer
        }
        defer { copies.forEach { $0.deallocate() } }
        let typePointers: [UnsafePointer<CChar>?] = names.map { $0.map { UnsafePointer<CChar>($0) } }
        let dataPointers: [UnsafePointer<UInt8>?] = copies.map { UnsafePointer<UInt8>($0) }
        let lengths = entries.map { $0.value.count }
        typePointers.withUnsafeBufferPointer { t in
            dataPointers.withUnsafeBufferPointer { d in
                lengths.withUnsafeBufferPointer { l in writeFn(Int32(entries.count), t.baseAddress, d.baseAddress, l.baseAddress) }
            }
        }
    }
    func read() -> [NSPasteboard.PasteboardType: Data] {
        var result: [NSPasteboard.PasteboardType: Data] = [:]
        for type in availableTypes() { result[type] = data(forType: type) }
        return result
    }
    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        let size = readFn(type.rawValue, nil, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        guard readFn(type.rawValue, &bytes, bytes.count) == size else { return nil }
        return Data(bytes)
    }
    func availableTypes() -> [NSPasteboard.PasteboardType] {
        let size = typesFn(nil, 0)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard typesFn(&buffer, Int(size)) == size else { return [] }
        return String(cString: buffer).split(separator: "\n").map { NSPasteboard.PasteboardType(String($0)) }
    }
    var externalChangeCount: Int { Int(changesFn()) }
}

/// The shell's clipboard functions; nil ones leave the pasteboard in process (headless tests).
@_cdecl("compositor_set_system_clipboard")
nonisolated public func compositorSetSystemClipboard(_ write: ClipboardWriteFn?, _ types: ClipboardTypesFn?,
                                                     _ read: ClipboardReadFn?, _ changes: ClipboardChangesFn?) {
    onMain {
        guard let write, let types, let read, let changes else { NSPasteboard.backend = nil; return }
        NSPasteboard.backend = SystemClipboard(write: write, types: types, read: read, changes: changes)
    }
}
