# Downloaded Photoshop fixtures

These are unmodified PSD files downloaded from
[psd-tools/psd-tools](https://github.com/psd-tools/psd-tools/tree/8f9a25ea98202061365701db54ce938931b27c09/tests/psd_files),
pinned to revision `8f9a25ea98202061365701db54ce938931b27c09`.
The upstream MIT license is retained in `LICENSE`. Each source URL, byte size and
SHA-256 checksum is in `manifest.json`; test runs verify the checksums and need no network.

| File | Coverage |
| --- | --- |
| masks.psd | 22 layers: nested groups, vector masks, opacity, hidden layers and text |
| blend-and-clipping.psd | 13 distinct layers: clipping chains, shapes and editable text |
| hidden-groups.psd | Hidden parent with visible child; compare with Photoshop's embedded merged image |
| layer_mask_data.psd | Raster masks and vector-rendered masks |
| layer_effects.psd | Text with effects; conversion warnings and persistence |
| adjustment_nested_composition_3.psd | Nested Curves adjustment, hidden layers, Multiply blend |
| smart-object-slice.psd | Rasterized smart object, conversion confirmation and cancellation |
| 16bit5x5.psd | Unsupported 16-bit error and recovery |
| pen-text.psd | Unsupported 32-bit error and recovery |

The metadata was read independently using `psd-tools==1.10.9`, rather than recorded
from Compositor's importer. `inspect_fixtures.py` regenerates it when that optional
package is installed; the normal test runner uses only Python and Pillow.
The flat layer list places each folder after its children, preserving bottom-to-top
sibling ordering. Vector-rendered mask channels and zero-sized mask records are not
expected to become editable raster masks. Actual raster masks must survive import.
`hidden-groups-merged.png` is extracted directly from the PSD's saved merged image.

## Large PSB stress fixture

The separate 1.27 GiB fixture lives in ignored `build/ui-e2e-large-psd/`, outside Git.
Source: [PhotoshopAPI benchmark collection](https://photoshopapi.readthedocs.io/en/latest/benchmarks.html),
[public download](https://drive.google.com/file/d/1N6eb_iA6YPx0PC8U1EAIoGL_izUgjwuD/view).
It is used locally for benchmarking; no redistribution license is assumed.

- Filename: `large_file_8bit.psb`
- Exact bytes: `1364358110`
- SHA-256: `2d33180d6ffd7b8fe3785311fca8f18cd5cac08d705362dff5d89a6450574468`
- Independently inspected: 8000 × 4500, RGB, 8-bit, 76 image layers and 4 groups.
- Layer bounds total 1,683,588,203 pixels before canvas clipping.

Run explicitly:

```sh
python3 tests/ui_e2e/run.py --case psb_large_import \
  --large-psb build/ui-e2e-large-psd/large_file_8bit.psb \
  --artifacts /tmp/compositor-large-psb-1
```

The stress case requires this exact downloaded file and checks its checksum. It
expects successful import of all 80 layers. If the app rejects it, the test records
the visible reason, verifies error recovery by creating and painting a document,
and still **fails the import test**. It never substitutes a tiny generated document.

On 2026-09-26 the release build rejected it at the current 800-megapixel document
budget. This is a known import limit, not a successful large-file import. The macOS
source and its budget were not changed to accommodate the test.
