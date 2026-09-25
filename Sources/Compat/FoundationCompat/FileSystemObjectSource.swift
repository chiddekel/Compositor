// macOS's vnode dispatch sources (DispatchSource.makeFileSystemObjectSource) on Linux, over inotify: the same API
// upstream's ProjectWatcher uses to notice a project package changing on disk. The descriptor names the file or
// directory (its path is read back from /proc); events are delivered on the queue given, like the real source's.
import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc

/// macOS opens a file "for event notification only"; inotify watches paths, so a plain read-only descriptor serves.
public let O_EVTONLY: Int32 = O_RDONLY

public final class DispatchSourceFileSystemObject: @unchecked Sendable {
    private let lock = NSLock()
    private let inotify: Int32
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var eventHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?
    private var pending: DispatchSource.FileSystemEvent = []
    private var cancelled = false
    public let handle: Int32
    public let mask: DispatchSource.FileSystemEvent
    /// The events seen since the handler last ran (valid inside the event handler).
    public var data: DispatchSource.FileSystemEvent { lock.withLock { pending } }
    public var isCancelled: Bool { lock.withLock { cancelled } }

    init(fileDescriptor: Int32, eventMask: DispatchSource.FileSystemEvent, queue: DispatchQueue) {
        handle = fileDescriptor
        mask = eventMask
        self.queue = queue
        inotify = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink("/proc/self/fd/\(fileDescriptor)", &buffer, Int(PATH_MAX))
        guard inotify >= 0, length > 0 else { return }
        let path = String(cString: Array(buffer[0..<length]) + [0])
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        var watch: UInt32 = 0
        if eventMask.contains(.write) || eventMask.contains(.extend) { watch |= UInt32(IN_MODIFY | IN_CLOSE_WRITE) }
        if eventMask.contains(.attrib) { watch |= UInt32(IN_ATTRIB) }
        if eventMask.contains(.delete) { watch |= UInt32(IN_DELETE_SELF) }
        if eventMask.contains(.rename) { watch |= UInt32(IN_MOVE_SELF) }
        // A directory's vnode "writes" when entries come and go (macOS); inotify reports those as child events.
        if isDirectory.boolValue, eventMask.contains(.write) || eventMask.contains(.link) {
            watch |= UInt32(IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO)
        }
        guard inotify_add_watch(inotify, path, watch) >= 0 else { return }
        let reader = DispatchSource.makeReadSource(fileDescriptor: inotify, queue: queue)
        reader.setEventHandler { [weak self] in self?.drain() }
        self.reader = reader
    }

    private func drain() {
        var events: DispatchSource.FileSystemEvent = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(inotify, &buffer, buffer.count)
            guard count > 0 else { break }
            var offset = 0
            while offset + MemoryLayout<inotify_event>.size <= count {
                let event = buffer.withUnsafeBytes { $0.load(fromByteOffset: offset, as: inotify_event.self) }
                let m = Int32(bitPattern: event.mask)
                if m & Int32(IN_MODIFY | IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO) != 0 { events.insert(.write) }
                if m & Int32(IN_MODIFY) != 0 { events.insert(.extend) }
                if m & Int32(IN_ATTRIB) != 0 { events.insert(.attrib) }
                if m & Int32(IN_CREATE | IN_DELETE) != 0 { events.insert(.link) }
                if m & Int32(IN_DELETE_SELF) != 0 { events.insert(.delete) }
                if m & Int32(IN_MOVE_SELF) != 0 { events.insert(.rename) }
                offset += MemoryLayout<inotify_event>.size + Int(event.len)
            }
        }
        let seen = events.intersection(mask)
        guard !seen.isEmpty else { return }
        let handler: (() -> Void)? = lock.withLock { pending = seen; return cancelled ? nil : eventHandler }
        handler?()
    }

    public func setEventHandler(qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], handler: (() -> Void)?) {
        lock.withLock { eventHandler = handler }
    }
    public func setCancelHandler(qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], handler: (() -> Void)?) {
        lock.withLock { cancelHandler = handler }
    }
    public func resume() { reader?.resume() }
    public func activate() { reader?.activate() }
    public func suspend() { reader?.suspend() }
    public func cancel() {
        let handler: (() -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            let h = cancelHandler
            cancelHandler = nil; eventHandler = nil
            return h
        }
        guard handler != nil || reader != nil else { if inotify >= 0 { close(inotify) }; return }
        if let reader {
            let fd = inotify
            reader.setCancelHandler { close(fd) }
            reader.cancel()
        } else if inotify >= 0 {
            close(inotify)
        }
        if let handler { queue.async(execute: handler) }
    }
}

extension DispatchSource {
    public static func makeFileSystemObjectSource(fileDescriptor: Int32, eventMask: DispatchSource.FileSystemEvent,
                                                  queue: DispatchQueue? = nil) -> DispatchSourceFileSystemObject {
        DispatchSourceFileSystemObject(fileDescriptor: fileDescriptor, eventMask: eventMask, queue: queue ?? .global())
    }
}
#endif
