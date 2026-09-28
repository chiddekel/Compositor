# macOS and GNU/Linux interchange verification

This procedure tests saved editable layers in both directions. Linux self-round-trip
results alone do not prove macOS interoperability. Use a macOS Compositor build
that supports format 11 (the pinned 1.3.4 implementation, `c28f827`, or an equivalent
compatible build). The protected macOS source in this checkout still writes
format 10; do not change it for this procedure.

## Generate and check the fixture on Linux

Build `CompositorHostBootstrap` with the same SDK/backend environment used for
the application. Run with isolated settings and the real Qt and Skia backends:

```sh
export LD_LIBRARY_PATH=/usr/lib/sdk/swift6/lib/swift/linux
export COMPOSITOR_SKIA_BRIDGE=$PWD/build/lib/libCompositorSkiaBridge.so
export COMPOSITOR_IMAGEIO_BACKEND=$PWD/build/lib/libCompositorQtImageIO.so
export QT_QPA_PLATFORM=offscreen
settings=$(mktemp -d)
export XDG_CONFIG_HOME=$settings/config XDG_DATA_HOME=$settings/data
export XDG_CACHE_HOME=$settings/cache XCTestConfigurationFilePath=interchange
.build/release/CompositorHostBootstrap --interchange fixture build/interchange-fixture
```

The output directory must not exist. It contains `original.comp`,
`linux-resaved.comp`, and `linux-reference.png`. The fixture includes a background,
a translucent transformed raster with an unlinked mask, a folder with nonuniform
mask coverage and opacity, and paragraph text with overlapping font/color ranges.
The text includes an emoji (two UTF-16 units), a combining accent and Greek omega.
Font metadata uses Helvetica, Helvetica-Bold and Courier; Linux may substitute
installed faces when creating the initial cached raster.

The comparator's positive and deliberate-damage checks can be reproduced in the
same environment:

```sh
python3 scripts/test-interchange.py .build/release/CompositorHostBootstrap build/interchange-fixture
```

Generation verifies that the Linux save/reopen/save preserves all manifest fields
and decoded assets. The reference PNG is a full-resolution export from the reopened
package. Do not regenerate the original after starting a round trip.

## Linux → macOS → Linux

1. Copy the entire `original.comp` directory to the Mac. Record the Mac app version
   and build/revision, macOS version, and installed font availability.
2. Open it in Compositor. Confirm the layer order, masked folder, detached raster
   mask, paragraph text, and mixed font/color runs. Before editing, export a PNG
   as `mac-unedited.png`, then save a copy as `mac-unedited.comp`.
3. Return the package and PNG to Linux. Compare them:

   ```sh
   .build/release/CompositorHostBootstrap --interchange verify \
     build/interchange-fixture/original.comp mac-unedited.comp \
     build/interchange-fixture/linux-reference.png mac-unedited.png
   ```

4. Separately, edit a copy on the Mac: replace text across a font/color boundary,
   undo and redo; recolor the emoji; change the font of a selected word. Confirm
   selection covers whole characters. Save `mac-edited.comp` and export
   `mac-edited.png`. Keep a record of the exact edits and resulting text/ranges.

## macOS → Linux → macOS

1. Send the Mac-edited package to Linux, then run:

   ```sh
   .build/release/CompositorHostBootstrap --interchange roundtrip \
     mac-edited.comp build/mac-edited-linux.comp
   ```

   This opens and saves through the real Linux package loader/writer, exports
   `build/mac-edited-linux.comp.png`, and compares metadata and assets. The output
   package must not exist.
2. Send that Linux-saved package back to the Mac. Open it and verify that text is
   still editable with the recorded font/color ranges and that masks/transforms
   remain editable. Export `mac-final.png` and save `mac-final.comp`.
3. Return both files and compare `mac-edited.comp` with `mac-final.comp`, and
   `mac-edited.png` with `mac-final.png`, using the same `verify` command.
4. Retain all packages, PNGs, command output, app/build versions, and the edit
   record. Report any failure before describing the round trip as verified.

## What the comparator proves

Every manifest field is compared recursively, including document/layer IDs,
layer order, active layer, groups, transforms, mask links/placements, and text
styles/ranges. Missing fields and differing values fail with a JSON path.
It compares decoded images rather than compressed PNG bytes. Mask coverage
must match exactly; color assets and optional flattened PNGs permit a maximum
one-byte channel difference after normalization to premultiplied RGBA8. Dimensions
must match. Missing, oversized or undecodable assets fail. Unsafe asset paths fail.

This is a strict retention check, not a general migration validator. Legitimate
intentional edits must be compared against the edited baseline, not the unedited
fixture. A comparator failure may identify a serialization default or renderer
difference rather than lost user data; investigate it explicitly. A pass does not
establish identical font rasterization after editing on systems with different
installed fonts, or prove UI editability without the manual Mac checks above.
