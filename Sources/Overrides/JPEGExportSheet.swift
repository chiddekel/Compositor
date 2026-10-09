// OVERRIDE for Compositor/UI/JPEGExportSheet.swift (tip renamed to ExportAsSheet): JPEG-only sheet for Qt exportJPEG.
// JPEGPreview lives in tip ExportAsSheet.swift.
import SwiftUI

struct JPEGExportSheet: View {
    let raster: ExportRaster
    let session: EditorSession
    let finish: (Data?) -> Void
    @State private var options: JPEGOptions
    /// The quality of the last export, which the next one starts from.
    private static let qualityKey = "jpegExportQuality"

    init(raster: ExportRaster, session: EditorSession, finish: @escaping (Data?) -> Void) {
        self.raster = raster
        self.session = session
        self.finish = finish
        var start = JPEGOptions()
        if let saved = UserDefaults.standard.object(forKey: Self.qualityKey) as? Double, saved.isFinite {
            start.quality = min(1, max(0, saved))
        }
        _options = State(initialValue: start)
    }
    @State private var result: JPEGResult?
    /// The preview's zoom, 1 being 100%; nil fits the whole image.
    @State private var zoom: Double?
    @Environment(\.displayScale) private var displayScale
    /// The zoom shown now, Fit's included.
    private var shownZoom: Double {
        zoom ?? JPEGPreview.fitZoom(width: raster.image.width, height: raster.image.height,
                                    in: JPEGPreview.frame, displayScale: displayScale)
    }
    @State private var readyOptions: JPEGOptions?
    @State private var error: String?

    var body: some View { sheet.roundedControls() }
    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Export JPEG").font(.title2.bold())
                Spacer()
                Button("Fit") { zoom = nil }.disabled(zoom == nil)
                    .help("Show the whole image (⌘0)")
                Button { zoomBy(1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(JPEGPreview.step(from: shownZoom, in: 1) == nil)
                    .help("Zoom in (⌘+), now \(percent). At 100% each pixel of the JPEG is one pixel of the screen, as on the canvas")
                Button { zoomBy(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(JPEGPreview.step(from: shownZoom, in: -1) == nil)
                    .help("Zoom out (⌘−), now \(percent)")
            }
            // Closer to the title row than the rest of the dialog's spacing.
            .padding(.bottom, -8)
            ZStack {
                Color(white: 0.12)
                if let result {
                    JPEGPreview(image: result.preview, pixelWidth: raster.image.width, pixelHeight: raster.image.height, zoom: $zoom)
                }
                if readyOptions != options && error == nil {
                    ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }.frame(width: JPEGPreview.frame.width, height: JPEGPreview.frame.height).clipped()
                .help("Drag or scroll to move around; double-click switches between Fit and 100%")
            HStack {
                Text("Quality")
                Slider(value: $options.quality, in: 0...1, step: 0.01)
                Text("\(Int((options.quality * 100).rounded()))%")
                    .monospacedDigit().frame(width: 45, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text("Background for transparency")
                DialogColorSwatch(title: "JPEG Background", color: matte, session: session)
                    .help("Color that fills transparent areas")
            }
            HStack(spacing: 12) {
                Text("\(raster.image.width.formatted()) × \(raster.image.height.formatted()) px · sRGB")
                    .foregroundStyle(.secondary)
                Spacer()
                if let error { Text(error).foregroundStyle(.red) }
                else if readyOptions == options, let result {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file)).monospacedDigit()
                } else { Text("Updating…").foregroundStyle(.secondary) }
                Button("Cancel") { DialogColorSwatch.closePicker(session); finish(nil) }.configuredNativeShortcut(.escape)
                Button("Export…") {
                    DialogColorSwatch.closePicker(session)
                    UserDefaults.standard.set(options.quality, forKey: Self.qualityKey)
                    finish(result?.data)
                }
                    .configuredNativeShortcut(.return)
                    .disabled(result == nil || readyOptions != options || error != nil)
            }
        }
        .padding(24)
        .onAppear { session.previewZoom = { command in
            switch command {
            case .zoomIn: zoomBy(1)
            case .zoomOut: zoomBy(-1)
            case .fit: zoom = nil
            case .actual: zoom = 1
            }
        } }
        .onDisappear { session.previewZoom = nil }
        .task(id: options) {
            let requested = options
            error = nil
            do {
                try await Task.sleep(for: .milliseconds(200))
                let encoded = try await ImageExporter.shared.jpeg(raster, options: requested)
                try Task.checkCancellation()
                result = encoded
                readyOptions = requested
            } catch is CancellationError {
                // A newer setting superseded this preview.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private var percent: String { "\(Int((shownZoom * 100).rounded()))%" }
    private func zoomBy(_ direction: Int) {
        if let next = JPEGPreview.step(from: shownZoom, in: direction) { zoom = next }
    }
    private var matte: Binding<PaletteColor> {
        Binding(get: { PaletteColor(red: options.red, green: options.green, blue: options.blue) },
                set: { options.red = $0.red; options.green = $0.green; options.blue = $0.blue })
    }
}
