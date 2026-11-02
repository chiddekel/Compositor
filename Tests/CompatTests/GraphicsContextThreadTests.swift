import AppKit
import CoreGraphics
import Foundation
import XCTest

private final class ContextObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func append(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}

final class GraphicsContextThreadTests: XCTestCase {
    func testCurrentContextAndSaveStackAreIndependentBetweenThreads() throws {
        func context() throws -> NSGraphicsContext {
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return NSGraphicsContext(cgContext: bitmap, flipped: false)
        }
        let first = try context(), second = try context()
        let firstReady = DispatchSemaphore(value: 0), secondReady = DispatchSemaphore(value: 0)
        let firstRestored = DispatchSemaphore(value: 0), done = DispatchGroup()
        let observations = ContextObservations()
        done.enter()
        DispatchQueue(label: "graphics-context-first").async {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = first
            firstReady.signal()
            guard secondReady.wait(timeout: .now() + 5) == .success else {
                observations.append(false); firstRestored.signal(); done.leave(); return
            }
            observations.append(NSGraphicsContext.current === first)
            NSGraphicsContext.restoreGraphicsState()
            observations.append(NSGraphicsContext.current == nil)
            firstRestored.signal()
            done.leave()
        }
        done.enter()
        DispatchQueue(label: "graphics-context-second").async {
            guard firstReady.wait(timeout: .now() + 5) == .success else {
                observations.append(false); secondReady.signal(); done.leave(); return
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = second
            secondReady.signal()
            guard firstRestored.wait(timeout: .now() + 5) == .success else {
                observations.append(false); done.leave(); return
            }
            observations.append(NSGraphicsContext.current === second)
            NSGraphicsContext.restoreGraphicsState()
            observations.append(NSGraphicsContext.current == nil)
            done.leave()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(observations.all, [true, true, true, true])
    }
}
