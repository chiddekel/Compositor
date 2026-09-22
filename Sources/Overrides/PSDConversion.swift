// OVERRIDE for the `PSDConversionRequest` value type declared in Compositor/UI/PSDConversionSheet.swift (UI/ is not
// compiled on Linux). `EditorSession` (Document, compiled unmodified) holds this as plain state; only the SwiftUI
// sheet that presents it lives in UI/. Field-for-field identical to upstream's declaration.

import Foundation

nonisolated struct PSDConversionRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let confirmTitle: String
    var conversions: [PSDConversion]
    /// The file is still being read: the sheet is up so the click feels answered, but it has
    /// nothing to report yet.
    var isReading: Bool
    init(id: UUID = UUID(), title: String, confirmTitle: String, conversions: [PSDConversion], isReading: Bool = false) {
        self.id = id
        self.title = title
        self.confirmTitle = confirmTitle
        self.conversions = conversions
        self.isReading = isReading
    }
}
