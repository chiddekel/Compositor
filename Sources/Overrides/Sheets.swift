// STAND-INS for the SwiftUI sheets Compositor/UI/{CanvasSizeSheet,ImageSizeSheet,JPEGExportSheet}.swift (UI/ is not
// compiled on Linux). Upstream's unmodified ProjectController builds these, hosts them with `NSHostingController`
// and presents them with `NSWindow.beginSheet`. The initialisers match upstream's exactly; presentation is the Qt
// shell's job: it installs `NSWindow.sheetPresenter`, reads the sheet from
// `sheet.contentViewController?.representedRootView`, shows its own dialog and calls `completion`. With no host
// installed, a sheet settles as "cancelled", so headless runs and tests never hang.

import Foundation
import AppKit
import SwiftUI

@MainActor struct CanvasSizeSheet: View, SheetAutoResolving {
    let document: CanvasDocument
    let foreground: PaletteColor
    let background: PaletteColor
    let completion: (CanvasSizeOptions?) -> Void
    init(document: CanvasDocument, foreground: PaletteColor, background: PaletteColor,
         completion: @escaping (CanvasSizeOptions?) -> Void) {
        self.document = document; self.foreground = foreground; self.background = background; self.completion = completion
    }
    func resolveWithoutHost() { completion(nil) }
}

@MainActor struct ImageSizeSheet: View, SheetAutoResolving {
    let document: CanvasDocument
    let completion: (ImageSizeOptions?) -> Void
    init(document: CanvasDocument, completion: @escaping (ImageSizeOptions?) -> Void) {
        self.document = document; self.completion = completion
    }
    func resolveWithoutHost() { completion(nil) }
}

@MainActor struct JPEGExportSheet: View, SheetAutoResolving {
    let raster: ExportRaster
    let completion: (Data?) -> Void
    init(raster: ExportRaster, completion: @escaping (Data?) -> Void) { self.raster = raster; self.completion = completion }
    func resolveWithoutHost() { completion(nil) }
}
