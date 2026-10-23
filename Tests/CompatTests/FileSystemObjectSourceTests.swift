import Dispatch
import Foundation
import XCTest
import FoundationCompat

/// Upstream's ProjectWatcher arms three vnode sources per open project. Linux limits each user to
/// fs.inotify.max_user_instances (often 128, most held by the desktop): every source must share one instance,
/// or watches silently stop firing once the limit is reached.
final class FileSystemObjectSourceTests: XCTestCase {
    private func inotifyInstances() -> Int {
        let fds = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
        return fds.filter { (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\($0)")) == "anon_inode:inotify" }.count
    }

    func testMoreSourcesThanTheInstanceLimitShareOneInstanceAndAllFire() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = inotifyInstances()
        let fired = DispatchGroup(), lock = NSLock()
        var events: [Int: DispatchSource.FileSystemEvent] = [:]
        var sources: [DispatchSourceFileSystemObject] = [], descriptors: [Int32] = []
        // 160 files, plus a second source on each of the first 20 (one path, two sources): 180 sources.
        let files = (0..<160).map { directory.appendingPathComponent("file\($0)") }
        for file in files { XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data())) }
        for (index, file) in (files + files.prefix(20)).enumerated() {
            let descriptor = open(file.path, O_EVTONLY)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend], queue: .global())
            fired.enter()
            source.setEventHandler { [source] in
                let first = lock.withLock { events.updateValue(source.data, forKey: index) == nil }
                if first { fired.leave() }
            }
            source.resume()
            sources.append(source); descriptors.append(descriptor)
        }
        XCTAssertLessThanOrEqual(inotifyInstances() - before, 1, "every source must share one inotify instance")
        for file in files { try Data("changed".utf8).write(to: file) }
        XCTAssertEqual(fired.wait(timeout: .now() + 10), .success, "a source sharing the instance missed its file's change")
        XCTAssertEqual(lock.withLock { events.count }, 180)
        XCTAssertTrue(lock.withLock { events.values.allSatisfy { $0.contains(.write) } })

        // Cancelling one of two sources on a path keeps the other watching; cancelling both ends the watch.
        sources[0].cancel()
        let survivor = DispatchSemaphore(value: 0)
        sources[160].setEventHandler { survivor.signal() }
        try Data("again".utf8).write(to: files[0])
        XCTAssertEqual(survivor.wait(timeout: .now() + 5), .success, "the remaining source on a shared path stopped firing")
        for source in sources { source.cancel() }
        for descriptor in descriptors { close(descriptor) }
    }
}
