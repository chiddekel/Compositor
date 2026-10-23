// macOS's vnode dispatch sources (DispatchSource.makeFileSystemObjectSource) on Linux, over inotify: the same API
// upstream's ProjectWatcher uses to notice a project package changing on disk. The descriptor names the file or
// directory (its path is read back from /proc); events are delivered on the queue given, like the real source's.
// All sources share one inotify instance: a user may own only fs.inotify.max_user_instances of them (often 128,
// most taken by the desktop), and each open project watches three paths, re-armed after every change.
import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc

/// macOS opens a file "for event notification only"; inotify watches paths, so a plain read-only descriptor serves.
public let O_EVTONLY: Int32 = O_RDONLY

/// The process's one inotify instance and its watches: each watch descriptor serves every source on that path.
private final class SharedInotify: @unchecked Sendable {
    static let shared = SharedInotify()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "compat.inotify")
    private let descriptor = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
    private var reader: DispatchSourceRead?
    private var watchers: [Int32: [DispatchSourceFileSystemObject]] = [:]

    private init() {
        guard descriptor >= 0 else { return }
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler { [weak self] in self?.drain() }
        reader.resume()
        self.reader = reader
    }

    /// Adds `watch` events on `path` for `source`; the descriptor's mask grows to cover every source on it.
    func add(_ source: DispatchSourceFileSystemObject, path: String, watch: UInt32) -> Int32? {
        guard descriptor >= 0 else { return nil }
        return lock.withLock {
            let wd = inotify_add_watch(descriptor, path, watch | UInt32(IN_MASK_ADD))
            guard wd >= 0 else { return nil }
            watchers[wd, default: []].append(source)
            return wd
        }
    }

    func remove(_ source: DispatchSourceFileSystemObject, wd: Int32) {
        lock.withLock {
            watchers[wd]?.removeAll { $0 === source }
            if watchers[wd]?.isEmpty == true { watchers[wd] = nil; inotify_rm_watch(descriptor, wd) }
        }
    }

    private func drain() {
        var events: [Int32: DispatchSource.FileSystemEvent] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            var offset = 0
            while offset + MemoryLayout<inotify_event>.size <= count {
                let event = buffer.withUnsafeBytes { $0.load(fromByteOffset: offset, as: inotify_event.self) }
                let m = Int32(bitPattern: event.mask)
                var seen: DispatchSource.FileSystemEvent = []
                if m & Int32(IN_MODIFY | IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO) != 0 { seen.insert(.write) }
                if m & Int32(IN_MODIFY) != 0 { seen.insert(.extend) }
                if m & Int32(IN_ATTRIB) != 0 { seen.insert(.attrib) }
                if m & Int32(IN_CREATE | IN_DELETE) != 0 { seen.insert(.link) }
                if m & Int32(IN_DELETE_SELF) != 0 { seen.insert(.delete) }
                if m & Int32(IN_MOVE_SELF) != 0 { seen.insert(.rename) }
                events[event.wd, default: []].formUnion(seen)
                // The kernel dropped this watch (its path is gone); the number may be reused for another path.
                if m & Int32(IN_IGNORED) != 0 { lock.withLock { _ = watchers.removeValue(forKey: event.wd) } }
                offset += MemoryLayout<inotify_event>.size + Int(event.len)
            }
        }
        for (wd, seen) in events {
            for source in lock.withLock({ watchers[wd] ?? [] }) { source.deliver(seen) }
        }
    }
}

public final class DispatchSourceFileSystemObject: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var wd: Int32?
    private var eventHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?
    private var pending: DispatchSource.FileSystemEvent = []
    private var resumed = false
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
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink("/proc/self/fd/\(fileDescriptor)", &buffer, Int(PATH_MAX))
        guard length > 0 else { return }
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
        wd = SharedInotify.shared.add(self, path: path, watch: watch)
    }

    /// Events reach the handler on the source's queue while it is resumed (upstream resumes each source at once).
    fileprivate func deliver(_ events: DispatchSource.FileSystemEvent) {
        let seen = events.intersection(mask)
        guard !seen.isEmpty else { return }
        queue.async { [self] in
            let handler: (() -> Void)? = lock.withLock {
                pending = seen
                return cancelled || !resumed ? nil : eventHandler
            }
            handler?()
        }
    }

    public func setEventHandler(qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], handler: (() -> Void)?) {
        lock.withLock { eventHandler = handler }
    }
    public func setCancelHandler(qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], handler: (() -> Void)?) {
        lock.withLock { cancelHandler = handler }
    }
    public func resume() { lock.withLock { resumed = true } }
    public func activate() { resume() }
    public func suspend() { lock.withLock { resumed = false } }
    public func cancel() {
        let (handler, wd): ((() -> Void)?, Int32?) = lock.withLock {
            guard !cancelled else { return (nil, nil) }
            cancelled = true
            let h = cancelHandler
            cancelHandler = nil; eventHandler = nil
            return (h, self.wd)
        }
        if let wd { SharedInotify.shared.remove(self, wd: wd) }
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
