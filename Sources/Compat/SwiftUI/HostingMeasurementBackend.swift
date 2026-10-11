import Foundation

/// Renderer-owned natural sizes. A headless process without a widget renderer leaves these bounds unknown.
@MainActor public enum HostingMeasurementBackend {
    public typealias MeasureFn = @convention(c) (UnsafePointer<UInt8>?, Int, Double, Double,
                                                UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?) -> Int32
    private static var measureFn: MeasureFn?
    public static func install(_ measure: MeasureFn?) { measureFn = measure }

    static func measure(_ node: RenderNode, proposal: ProposedViewSize) -> CGSize? {
        guard ["Text", "Button", "Toggle", "TextField", "Slider", "Picker", "Label", "Image"].contains(node.kind),
              let measureFn, let data = try? JSONEncoder().encode(node.wire()) else { return nil }
        var width = 0.0, height = 0.0
        let result = data.withUnsafeBytes { bytes in
            measureFn(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                      proposal.width ?? -1, proposal.height ?? -1, &width, &height)
        }
        guard result == 1, width.isFinite, height.isFinite, width >= 0, height >= 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
