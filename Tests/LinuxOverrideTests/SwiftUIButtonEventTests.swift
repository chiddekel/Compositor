import AppKit
import Foundation
import Testing
@testable import Compositor

@MainActor
struct SwiftUIButtonEventTests {
    @Test func activationModifiersAreScopedToTheAction() async throws {
        let handle = await Task.detached { compositorSessionCreate() }.value
        defer { Sessions.entries.removeValue(forKey: handle) }
        let entry = try #require(Sessions.entries[handle])
        let savedEvent = NSApp.currentEvent, savedModifiers = NSEvent.modifierFlags
        defer { NSApp.currentEvent = savedEvent; NSEvent.modifierFlags = savedModifiers }
        let prior = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0))
        NSApp.currentEvent = prior
        NSEvent.modifierFlags = .shift
        var eventFlags: NSEvent.ModifierFlags = [], globalFlags: NSEvent.ModifierFlags = []
        entry.actionHandlers["ActivationProbe"] = ["button": ["action": { _ in
            eventFlags = NSApp.currentEvent?.modifierFlags ?? []
            globalFlags = NSEvent.modifierFlags
        }, "pointer": { _ in NSEvent.modifierFlags = .control }]]
        for bits in [15, 0] {
            let payload = try JSONSerialization.data(withJSONObject: ["modifiers": bits])
            let result = await Task.detached {
                "ActivationProbe".withCString { panel in
                    "button".withCString { node in
                        "action".withCString { key in
                            payload.withUnsafeBytes { bytes in
                                compositorSessionDispatchSwiftUIAction(handle, panel, node, key,
                                    bytes.bindMemory(to: UInt8.self).baseAddress, payload.count)
                            }
                        }
                    }
                }
            }.value
            #expect(result == 0)
            let expected: NSEvent.ModifierFlags = bits == 0 ? [] : [.command, .option, .control, .shift]
            #expect(eventFlags == expected && globalFlags == expected)
            #expect(NSApp.currentEvent === prior)
            #expect(NSEvent.modifierFlags == .shift)
        }
        let result = await Task.detached {
            "ActivationProbe".withCString { panel in
                "button".withCString { node in
                    "pointer".withCString { key in
                        compositorSessionDispatchSwiftUIAction(handle, panel, node, key, nil, 0)
                    }
                }
            }
        }.value
        #expect(result == 0)
        #expect(NSEvent.modifierFlags == .control)
    }
}
