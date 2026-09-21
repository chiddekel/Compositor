// FoundationCompat — the few Apple-Foundation APIs swift-corelibs-foundation lacks and upstream code uses:
// `FileWrapper`, `NSFileCoordinator`, security-scoped URL access and `autoreleasepool`. Files that import only
// Foundation see these through the implicit `-import-module FoundationCompat` build setting, so upstream sources
// stay unmodified.

import Foundation

/// Objective-C's out-error parameter; `error: &coordinationError` binds to it exactly as on Apple platforms.
public typealias NSErrorPointer = UnsafeMutablePointer<NSError?>?

public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result { try body() }

extension URL {
    /// Sandbox scope is a macOS concept; on Linux (and in Flatpak, through portals) the URL is already usable.
    public func startAccessingSecurityScopedResource() -> Bool { false }
    public func stopAccessingSecurityScopedResource() {}
}

/// Reads and writes a directory of files as one document package (Apple's `FileWrapper`, the subset the project
/// store uses: regular files, directories, atomic package writes and reading a package back).
open class FileWrapper {
    public struct WritingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let atomic = WritingOptions(rawValue: 1 << 0)
        public static let withNameUpdating = WritingOptions(rawValue: 1 << 1)
    }
    public struct ReadingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let immediate = ReadingOptions(rawValue: 1 << 0)
        public static let withoutMapping = ReadingOptions(rawValue: 1 << 1)
    }

    public var preferredFilename: String?
    public var filename: String?
    public private(set) var regularFileContents: Data?
    public private(set) var fileWrappers: [String: FileWrapper]?
    public var isRegularFile: Bool { regularFileContents != nil }
    public var isDirectory: Bool { fileWrappers != nil }

    public init(regularFileWithContents contents: Data) { regularFileContents = contents }

    public init(directoryWithFileWrappers wrappers: [String: FileWrapper]) {
        fileWrappers = wrappers
        for (name, wrapper) in wrappers { wrapper.preferredFilename = name; wrapper.filename = name }
    }

    public init(url: URL, options: ReadingOptions = []) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if isDir.boolValue {
            var children: [String: FileWrapper] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                children[name] = try FileWrapper(url: url.appendingPathComponent(name), options: options)
            }
            fileWrappers = children
        } else {
            regularFileContents = try Data(contentsOf: url)
        }
        preferredFilename = url.lastPathComponent
        filename = url.lastPathComponent
    }

    @discardableResult
    public func addRegularFile(withContents data: Data, preferredFilename: String) -> String {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = preferredFilename; wrapper.filename = preferredFilename
        fileWrappers?[preferredFilename] = wrapper
        return preferredFilename
    }

    /// Writes into `url`. Atomic writes build a sibling temporary package and swap it in.
    public func write(to url: URL, options: WritingOptions = [], originalContentsURL: URL?) throws {
        let fm = FileManager.default
        let target = options.contains(.atomic)
            ? url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            : url
        try writeContents(to: target)
        if options.contains(.atomic) {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: target, to: url)
        }
    }

    private func writeContents(to url: URL) throws {
        let fm = FileManager.default
        if let data = regularFileContents {
            try data.write(to: url)
        } else if let wrappers = fileWrappers {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, wrapper) in wrappers { try wrapper.writeContents(to: url.appendingPathComponent(name)) }
        }
    }
}

/// Coordinates file access with other processes on Apple platforms. Linux has no file-coordination service, so the
/// accessor simply runs on the given URL; atomic replacement is the caller's `write(... .atomic)`.
open class NSFileCoordinator {
    public struct ReadingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let withoutChanges = ReadingOptions(rawValue: 1 << 0)
        public static let resolvesSymbolicLink = ReadingOptions(rawValue: 1 << 1)
    }
    public struct WritingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let forDeleting = WritingOptions(rawValue: 1 << 0)
        public static let forMoving = WritingOptions(rawValue: 1 << 1)
        public static let forMerging = WritingOptions(rawValue: 1 << 4)
        public static let forReplacing = WritingOptions(rawValue: 1 << 3)
    }
    public init() {}
    public init(filePresenter: AnyObject?) {}

    public func coordinate(readingItemAt url: URL, options: ReadingOptions = [],
                           error outError: NSErrorPointer, byAccessor reader: (URL) -> Void) {
        reader(url)
    }

    public func coordinate(writingItemAt url: URL, options: WritingOptions = [],
                           error outError: NSErrorPointer, byAccessor writer: (URL) -> Void) {
        writer(url)
    }

    public func coordinate(readingItemAt readURL: URL, options readOptions: ReadingOptions = [],
                           writingItemAt writeURL: URL, options writeOptions: WritingOptions = [],
                           error outError: NSErrorPointer, byAccessor accessor: (URL, URL) -> Void) {
        accessor(readURL, writeURL)
    }
}
