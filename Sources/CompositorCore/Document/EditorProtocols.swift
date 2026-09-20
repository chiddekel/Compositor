// SOLID Architecture: Interface Segregation Principle (ISP) & Dependency Inversion Principle (DIP)
// Fine-grained, role-focused interfaces separating the document editor's capabilities:
// - LayerManipulating: layer hierarchy, visibility, transforms
// - MaskManipulating: non-destructive layer masks
// - BrushPainting: pointer/stylus raster painting and clone/healing strokes
// - CanvasOperations: canvas dimensions, cropping, resampling
// - SubjectMatteOperations: foreground extraction and smart matte refinement

import Foundation

/// Segregated interface for layer management and transformations.
protocol LayerManipulating: AnyObject {
    var activeLayerID: UUID? { get }
    var canEditLayers: Bool { get }
    func addBlankLayer() throws
    func deleteLayer() throws
    func moveLayer(dx: CGFloat, dy: CGFloat) throws
    func flipLayers(horizontally: Bool)
}

/// Segregated interface for non-destructive layer mask workflows.
protocol MaskManipulating: AnyObject {
    func addLayerMask(revealing: Bool)
    func deleteLayerMask()
    func invertLayerMask()
    func setLayerMaskEnabled(_ enabled: Bool)
    func setLayerMaskLinked(_ linked: Bool)
}

/// Segregated interface for raster brush drawing and healing strokes.
protocol BrushPainting: AnyObject {
    func beginBrush(at point: CGPoint, settings: BrushSettings, mask: Bool,
                    cloneOffset: CGSize?, sampleAllLayers: Bool) throws
    func continueBrush(at point: CGPoint) throws
    func finishBrush() throws
    func cancelBrush()
}

/// Segregated interface for canvas geometry and sizing operations.
protocol CanvasOperations: AnyObject {
    func createDocument(width: Int, height: Int, emptyLayer: Bool) throws
    func resizeCanvas(width: Int, height: Int, anchor: Int, fill: CanvasExtensionColor?) throws
    func cropCanvas(to rect: CGRect) throws
    func resizeImage(width: Int, height: Int, resolution: Double?, sampling: LayerSampling) throws
}

extension CanvasOperations {
    func createDocument(width: Int, height: Int) throws {
        try createDocument(width: width, height: height, emptyLayer: false)
    }
}

/// Segregated interface for subject extraction and matte refinement.
protocol SubjectMatteOperations: AnyObject {
    func removeBackground(settings: FilterSettings) throws
}

// EditorSession conforms to all segregated interfaces, satisfying ISP for clients.
extension EditorSession: LayerManipulating, MaskManipulating, BrushPainting, CanvasOperations, SubjectMatteOperations {}
