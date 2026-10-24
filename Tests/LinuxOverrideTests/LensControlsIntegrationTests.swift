import Foundation
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct LensControlsIntegrationTests {
    private func nodes(_ node: RenderNode) -> [RenderNode] { [node] + node.children.flatMap(nodes) }

    @Test(arguments: [false, true])
    func prismDirectionRoundTripsThroughNativeActionsWithoutCommittingPixels(preview: Bool) async throws {
        let handle = await Task.detached { compositorSessionCreate() }.value
        let entry = try #require(Sessions.entries[handle])
        let session = entry.editor.session
        defer {
            session.cancelFilter()
            discardRenderedPanels(handle, entry: entry)
            Sessions.entries.removeValue(forKey: handle)
        }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        for pixel in 0..<(16 * 16) { pixels[pixel * 4 + 3] = 255 }
        for y in 7...8 { for x in 7...8 { for channel in 0..<3 { pixels[(y * 16 + x) * 4 + channel] = 255 } } }
        #expect(entry.editor.importRGBA(pixels, width: 16, height: 16,
                                       name: "Prism", replacing: true) == 0)
        let layer = try #require(session.document?.layers.first)
        let original = try #require(layer.asset?.image).portableImage.bytes
        var settings = FilterSettings()
        settings.lens.effect = .prism
        settings.lens.prismCopies = 1
        settings.lens.prismOffset = 25
        settings.lens.prismAmount = 100
        let edit = try FilterEdit(kind: .lensEffects, layer: layer, selection: nil, settings: settings)
        edit.preview = preview
        session.filterEdit = edit
        let undoCount = session.history.undoCount
        func flatten(_ node: RenderNodeWire) -> [RenderNodeWire] { [node] + node.children.flatMap(flatten) }
        func direction() throws -> RenderNodeWire {
            let tree = try #require(resolvePanel("FilterSheet", entry: entry))
            return try #require(flatten(tree).first { node in
                node.kind == "Picker" && flatten(node).contains { $0.stringParams["text"] == "Both Ways" }
            })
        }
        #expect(try direction().stringParams["selection"] == "false")
        for choice in ["true", "false"] {
            let nodeID = try direction().id
            let payload = try JSONEncoder().encode(choice)
            let result = await Task.detached {
                "FilterSheet".withCString { panel in
                    nodeID.withCString { node in
                        "selection".withCString { key in
                            payload.withUnsafeBytes { bytes in
                                compositorSessionDispatchSwiftUIAction(handle, panel, node, key,
                                    bytes.bindMemory(to: UInt8.self).baseAddress, payload.count)
                            }
                        }
                    }
                }
            }.value
            #expect(result == 0)
            #expect(edit.settings.lens.prismBothWays == (choice == "true"))
            #expect(try direction().stringParams["selection"] == choice)
            if preview {
                let deadline = ContinuousClock.now + .seconds(5)
                while edit.preparedSettings != edit.settings && edit.previewError == nil && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(2))
                }
                #expect(edit.previewError == nil)
                #expect(edit.preparedSettings == edit.settings, "The preview catches up with the selected direction")
                let rendered = try #require(edit.preparedPreview).portableImage
                let rightEcho = rendered.bytes[8 * rendered.bytesPerRow + 12 * 4 + 1]
                if choice == "true" { #expect(rightEcho > 100) }
                else { #expect(rightEcho == 0) }
            }
            #expect(session.history.undoCount == undoCount)
            #expect(try #require(session.document?.layers.first?.asset?.image).portableImage.bytes == original)
        }
        session.cancelFilter()
        #expect(session.filterEdit == nil)
        #expect(session.history.undoCount == undoCount)
        #expect(try #require(session.document?.layers.first?.asset?.image).portableImage.bytes == original)
    }

    @Test(arguments: LensEffect.allCases)
    func upstreamControlsResolveForEveryEffect(effect: LensEffect) throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 255, count: 4 * 4 * 4), width: 4, height: 4,
                                  name: "Lens", replacing: true) == 0)
        let layer = try #require(editor.session.document?.layers.first)
        var settings = FilterSettings()
        settings.lens.effect = effect
        editor.session.filterEdit = try FilterEdit(kind: .lensEffects, layer: layer, selection: nil, settings: settings)
        let labels = nodes(ViewResolver.resolve(FilterSheet(session: editor.session))).compactMap { $0.stringParams["text"] }
        #expect(labels.contains("Preview"))
        #expect(labels.contains("OK"))
        for option in LensEffect.allCases { #expect(labels.contains(option.rawValue)) }
        let specific: String
        switch effect {
        case .anamorphicFlare: specific = "Blue"
        case .starburst: specific = "Points"
        case .mist: specific = "Strength"
        case .prism: specific = "Copies"
        case .bokeh: specific = "Ring"
        }
        #expect(labels.contains(specific))
        if effect == .prism {
            #expect(labels.contains("Both Ways"))
            #expect(labels.contains("Blur"))
        }
    }
}
