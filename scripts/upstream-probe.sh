#!/bin/sh
# Phase-0 feasibility probe: compiles upstream Compositor/{Document,IO,Rendering} UNMODIFIED
# against stub Apple modules and prints the distinct missing Apple symbols (the shim work list).
# Usage: scripts/upstream-probe.sh [work-dir]   (run inside the Flatpak SDK, see docs/upstream-shim-worklist.md)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${1:-${TMPDIR:-/tmp}/upstream-probe}"
rm -rf "$W"; mkdir -p "$W/Sources"
for m in AppKit CoreImage SwiftUI; do mkdir -p "$W/Sources/$m"; done
printf '@_exported import Foundation\n@_exported import CoreGraphics\n' > "$W/Sources/AppKit/stub.swift"
cp "$W/Sources/AppKit/stub.swift" "$W/Sources/CoreImage/stub.swift"
printf '@_exported import Foundation\n@_exported import CoreGraphics\n@_exported import Observation\n' > "$W/Sources/SwiftUI/stub.swift"
for m in Vision UniformTypeIdentifiers Accelerate ImageIO; do mkdir -p "$W/Sources/$m"; cp "$W/Sources/AppKit/stub.swift" "$W/Sources/$m/stub.swift"; done
# CoreGraphics = the port's current compat (copied so the two domain-coupled bits can be neutralised for the probe).
mkdir -p "$W/Sources/CoreGraphics"
cp -r "$ROOT/Sources/CompositorCore/CoreGraphicsCompat" "$W/Sources/CoreGraphics/"
cp "$ROOT/Sources/CompositorCore/"{CompositorGeometry,CompositorRaster,CompositeOver}.swift "$W/Sources/CoreGraphics/"
echo '@_exported import Foundation' > "$W/Sources/CoreGraphics/stub.swift"
python3 - "$W" <<'PY'
import sys
W=sys.argv[1]
p=W+'/Sources/CoreGraphics/CoreGraphicsCompat/Color.swift'; s=open(p).read()
a=s.index('extension LayerBlendMode {'); i=s.index('{',a); d=0; j=i
while True:
    d+= (s[j]=='{') - (s[j]=='}')
    if d==0: break
    j+=1
open(p,'w').write(s[:a]+s[j+1:])
p=W+'/Sources/CoreGraphics/CoreGraphicsCompat/Context.swift'; s=open(p).read()
a=s.index('    private func drawSwift('); b=s.index('\n    }\n',a)+7
open(p,'w').write(s[:a]+'    private func drawSwift(_ image: PortableImage, in rect: CGRect, opacity: Double) {}\n'+s[b:])
PY
# Upstream: only Document, IO, Rendering (UI/App files are the Qt shell's job); C kernels become their own target.
mkdir -p "$W/Sources/UpstreamProbe" "$W/Sources/UpstreamKernels/include"
for d in Document IO Rendering; do ln -s "$ROOT/Compositor/$d" "$W/Sources/UpstreamProbe/$d"; done
for f in "$ROOT"/Compositor/Rendering/*.c "$ROOT"/Compositor/Rendering/*.h; do
  ln -s "$f" "$W/Sources/UpstreamKernels/$(basename "$f")"; ln -s "$f" "$W/Sources/UpstreamKernels/include/$(basename "$f")"; done
CEXCL=$(ls "$ROOT"/Compositor/Rendering | grep -E '\.(c|h)$' | sed 's#.*#"Rendering/&"#' | paste -sd,)
cat > "$W/Package.swift" <<PKG
// swift-tools-version:6.0
import PackageDescription
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]
var targets: [Target] = [.target(name: "CoreGraphics", path: "Sources/CoreGraphics", swiftSettings: v5),
  .target(name: "UpstreamKernels", path: "Sources/UpstreamKernels", publicHeadersPath: "include")]
let apple = ["AppKit","CoreImage","SwiftUI","Vision","UniformTypeIdentifiers","Accelerate","ImageIO"]
for m in apple { targets.append(.target(name: m, dependencies: ["CoreGraphics"], path: "Sources/\(m)", swiftSettings: v5)) }
targets.append(.target(name: "UpstreamProbe", dependencies: (apple + ["CoreGraphics","UpstreamKernels"]).map { .byName(name: \$0) },
  path: "Sources/UpstreamProbe",
  exclude: [$CEXCL,"IO/CompositorApplicationDelegate.swift","IO/ProjectController.swift","IO/ImageFileDrop.swift",
    "Rendering/EditorCanvas.swift","Rendering/InlineTextEditor.swift","Rendering/BrushCursorOverlay.swift","Rendering/SampleRingOverlay.swift",
    "Rendering/MetalBrushCoverage.swift","Rendering/MetalLayerEffects.swift"],
  swiftSettings: v5 + [.unsafeFlags(["-import-objc-header","$ROOT/Compositor/Compositor-Bridging-Header.h","-Xcc","-I$ROOT/Compositor/Rendering"])]))
let package = Package(name: "Probe", products: [.library(name: "UpstreamProbe", targets: ["UpstreamProbe"])], targets: targets)
PKG
cd "$W" && swift build > build.log 2>&1 || true
grep "error:" build.log | grep -v '^ ' | sed -E 's#^.*Sources/UpstreamProbe/##' | sort -u > errors.txt
echo "distinct error lines: $(wc -l < errors.txt)  (see $W/errors.txt, $W/build.log)"
grep -ohE "cannot find (type )?'[A-Za-z0-9_]+' in scope" errors.txt | sed -E "s/.*'([^']+)'.*/\1/" | sort -u | tr '\n' ' '; echo
