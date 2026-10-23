import Foundation
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct ShellRequestOwnershipTests {
    @Test func closingLifecycleCallbacksKeepTheirOwnerAndCannotQueueIntoTheSurvivor() async throws {
        let saved = ShellProjects.pending
        defer { ShellProjects.pending = saved }
        ShellProjects.pending = []
        let closing = await Task.detached { compositorSessionCreate() }.value
        let survivor = await Task.detached { compositorSessionCreate() }.value
        let entry = try #require(Sessions.entries[closing])
        let panel = "CloseOwnershipProbe"
        entry.renderedPanels.insert(panel)
        var observedOwner: UInt64?
        var restoredOwner: UInt64?
        var deferred: Task<Void, Never>?
        var node = RenderNode(kind: "text")
        node.modifiers.append(.onDisappear {
            observedOwner = ShellProjects.requestOwner
            ShellProjects.enqueue("save")
            deferred = Task { @MainActor in ShellProjects.enqueue("exportPNG") }
        })
        ChangeTracker.process(scope: entry.panelScope(panel), root: node)
        await Task.detached {
            onMain {
                ShellProjects.$requestOwner.withValue(survivor) {
                    compositorSessionClose(closing)
                    restoredOwner = ShellProjects.requestOwner
                }
            }
        }.value
        if let deferred { await deferred.value }
        #expect(observedOwner == closing)
        #expect(restoredOwner == survivor)
        #expect(ShellProjects.pending.isEmpty)
        #expect(ShellProjects.requestOwner == nil)
        #expect(Sessions.entries[survivor] != nil)
        await Task.detached { compositorSessionClose(survivor) }.value
    }

    @Test func anotherWindowCannotDrainRequestsAndShortBuffersRetainThem() async throws {
        let saved = ShellProjects.pending
        defer { ShellProjects.pending = saved }
        ShellProjects.pending = [.init(name: "imageSize", handle: 101), .init(name: "canvasSize", handle: 202),
                                 .init(name: "save", handle: 101)]
        func drain(_ handle: UInt64) async throws -> [String] {
            let (size, result, bytes) = await Task.detached {
                let size = compositorTakeSessionShellRequests(handle, nil, 0)
                var bytes = [UInt8](repeating: 0, count: Int(size))
                let result = bytes.withUnsafeMutableBufferPointer { compositorTakeSessionShellRequests(handle, $0.baseAddress, $0.count) }
                return (size, result, bytes)
            }.value
            #expect(result == size)
            return try JSONDecoder().decode([String].self, from: Data(bytes))
        }
        #expect(try await drain(303).isEmpty)
        #expect(ShellProjects.pending.count == 3)
        let shortResult = await Task.detached {
            var short: UInt8 = 0
            return compositorTakeSessionShellRequests(101, &short, 1)
        }.value
        #expect(shortResult == -1)
        #expect(ShellProjects.pending.count == 3)
        #expect(try await drain(101) == ["imageSize", "save"])
        #expect(try await drain(101).isEmpty)
        #expect(try await drain(202) == ["canvasSize"])
        #expect(ShellProjects.pending.isEmpty)
    }

    @Test func closingAHandleDropsOnlyItsQueuedRequests() async {
        let saved = ShellProjects.pending
        defer { ShellProjects.pending = saved }
        let handle = await Task.detached { compositorSessionCreate() }.value
        ShellProjects.pending = [.init(name: "imageSize", handle: handle), .init(name: "save", handle: UInt64.max)]
        await Task.detached { compositorSessionClose(handle) }.value
        #expect(ShellProjects.pending.count == 1)
        #expect(ShellProjects.pending.first?.name == "save")
        #expect(ShellProjects.pending.first?.handle == UInt64.max)
        ShellProjects.$requestOwner.withValue(handle) { ShellProjects.enqueue("save") }
        #expect(ShellProjects.pending.count == 1)
    }

    @Test func aDeferredMenuTaskKeepsItsDispatchOwner() async {
        let saved = ShellProjects.pending
        defer { ShellProjects.pending = saved }
        ShellProjects.pending = []
        let handle = await Task.detached { compositorSessionCreate() }.value
        let task = ShellProjects.$requestOwner.withValue(handle) {
            Task { @MainActor in ShellProjects.enqueue("imageSize") }
        }
        #expect(ShellProjects.requestOwner == nil)
        await task.value
        #expect(ShellProjects.pending.count == 1)
        #expect(ShellProjects.pending.first?.handle == handle)
        await Task.detached { compositorSessionClose(handle) }.value
    }

    @Test func swiftUIActionRequestsUseTheSuppliedHandle() async throws {
        let saved = ShellProjects.pending
        defer { ShellProjects.pending = saved }
        ShellProjects.pending = []
        let handle = await Task.detached { compositorSessionCreate() }.value
        let entry = try #require(Sessions.entries[handle])
        entry.actionHandlers["OwnershipProbe"] = ["button": ["action": { _ in ShellProjects.enqueue("commandPalette") }]]
        let result = await Task.detached {
            "OwnershipProbe".withCString { panel in
                "button".withCString { node in
                    "action".withCString { key in compositorSessionDispatchSwiftUIAction(handle, panel, node, key, nil, 0) }
                }
            }
        }.value
        #expect(result == 0 && ShellProjects.pending.count == 1)
        #expect(ShellProjects.pending.first?.handle == handle)
        await Task.detached { compositorSessionClose(handle) }.value
    }

    @Test func swiftUIAndNestedDropActionsUseTheirHandlesAndRestoreTheCaller() async throws {
        let saved = ShellProjects.pending
        defer { ShellProjects.pending = saved }
        ShellProjects.pending = []
        let first = await Task.detached { compositorSessionCreate() }.value
        let second = await Task.detached { compositorSessionCreate() }.value
        let entry = try #require(Sessions.entries[first])
        let nested = try #require(Sessions.entries[second])
        var owners: [UInt64?] = []
        var deferred: Task<Void, Never>?
        var dropResult: Int32 = -99
        let payload = Data("{}".utf8)
        nested.resultHandlers["OwnershipProbe"] = ["drop": ["drop": { _ in
            owners.append(ShellProjects.requestOwner)
            ShellProjects.enqueue("popUpMenu")
            return 7
        }]]
        entry.actionHandlers["OwnershipProbe"] = ["button": ["action": { _ in
            owners.append(ShellProjects.requestOwner)
            ShellProjects.enqueue("commandPalette")
            dropResult = "OwnershipProbe".withCString { panel in
                "drop".withCString { node in
                    payload.withUnsafeBytes { bytes in
                        compositorSessionDispatchSwiftUIDropEvent(second, panel, node, node,
                            bytes.bindMemory(to: UInt8.self).baseAddress, payload.count)
                    }
                }
            }
            owners.append(ShellProjects.requestOwner)
            ShellProjects.enqueue("toggleCanvasOnly")
            deferred = Task { @MainActor in ShellProjects.enqueue("save") }
        }]]
        let (result, restored, outside) = await Task.detached {
            onMain {
                var restored: UInt64?
                let result = ShellProjects.$requestOwner.withValue(second) {
                    let result = "OwnershipProbe".withCString { panel in
                        "button".withCString { node in
                            "action".withCString { key in
                                compositorSessionDispatchSwiftUIAction(first, panel, node, key, nil, 0)
                            }
                        }
                    }
                    restored = ShellProjects.requestOwner
                    return result
                }
                return (result, restored, ShellProjects.requestOwner)
            }
        }.value
        await deferred?.value
        #expect(result == 0 && dropResult == 7)
        #expect(owners == [first, second, first])
        #expect(ShellProjects.pending.map(\.name) == ["commandPalette", "popUpMenu", "toggleCanvasOnly", "save"])
        #expect(ShellProjects.pending.map(\.handle) == [first, second, first, first])
        #expect(restored == second && outside == nil)
        await Task.detached { compositorSessionClose(first); compositorSessionClose(second) }.value
    }
}
