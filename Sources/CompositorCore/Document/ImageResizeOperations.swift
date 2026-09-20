import Foundation

extension EditorSession {
    func resizeImage(width: Int, height: Int, resolution: Double? = nil, sampling: LayerSampling = .high) throws {
        guard brushStroke == nil, filterEdit == nil, warpStroke == nil else { throw Failure.busy }
        guard let document else { throw Failure.noDocument }
        let options = ImageSizeOptions(width: width, height: height,
            resolution: resolution ?? document.resolution, sampling: sampling)
        let snapshot = try ProjectSnapshot(document: document, activeLayerID: activeLayerID)
        let resized = try ImageResizer.resizeSnapshot(snapshot, to: options)
        if width == document.width, height == document.height, options.resolution == document.resolution { return }
        var next = try resized.document()
        if let selection = document.selection {
            let sx = CGFloat(width) / CGFloat(document.width)
            let sy = CGFloat(height) / CGFloat(document.height)
            let scale = CGAffineTransform(scaleX: sx, y: sy)
            let path = selection.path.applying(scale)
            next.selection = DocumentSelection(path: path, antialiased: selection.antialiased)
        }
        history.begin("Image Size", document: document, selection: activeLayerID)
        replaceCurrentDocument(next)
        history.end(document: next, selection: activeLayerID)
    }
}
