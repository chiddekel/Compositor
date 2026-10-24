# Native text parity investigation

The format-18 candidate passes 140 of 173 native image comparisons. All nine
text comparisons remain unresolved. Their inputs use the bundled Inter Regular,
Bold and Light faces at 12, 24 and 36 points, drawing `Ag Ω` at `(4, 20)`.

Native capture run `40136860217` includes these recipes with default font
smoothing, smoothing disabled, antialiasing disabled and opaque black/white
backgrounds. All 18 integer and fractional font recipes resolve to the same
bundled font hashes. Each integer recipe's default alpha buffer matches the
corresponding native application corpus exactly.

## Isolating the backend

An isolated Qt executable registers the bundled faces, uses `fontFor` from
`host/QtTextFont.h`, and reproduces the layout and drawing in
`host/QtImageIO.cpp`. Its default output matches all nine current Linux alpha
buffers byte for byte. Whole-pixel translation searches from -3 through +3 in
each direction find the best alignment at `(0, 0)` for every case.

The diagnostic compares 17 variants per case: Qt's default, no, vertical and
full hinting; layout at 64 times the size; alternative baseline rounding;
outline rendering; and outline expansion with five stroke widths. None reaches
the existing 0.97 glyph-mask intersection-over-union threshold against native
default rendering. Disabling hinting improves eight default comparisons and
regresses Bold at 12 points. It cannot resolve these failures alone.

## Font smoothing changes coverage

Disabling smoothing in the native capture substantially reduces glyph coverage.
The following values sum the alpha channel divided by 255; they measure covered
pixel equivalents, rather than bounding-box area.

| Face and size | Native default | Native smoothing disabled | Qt hinting disabled |
| --- | ---: | ---: | ---: |
| Regular 12 | 108.04 | 74.12 | 74.55 |
| Regular 24 | 403.75 | 296.47 | 298.03 |
| Regular 36 | 831.16 | 669.76 | 671.27 |
| Bold 12 | 144.17 | 111.24 | 111.93 |
| Bold 24 | 550.37 | 446.88 | 448.68 |
| Bold 36 | 1162.97 | 1007.30 | 1009.96 |
| Light 12 | 92.58 | 57.46 | 57.77 |
| Light 24 | 339.00 | 229.04 | 230.47 |
| Light 36 | 684.27 | 519.07 | 519.05 |

Unhinted Qt coverage is within one percent of native coverage with smoothing
disabled in every case. Its glyph-mask overlap with that native variant ranges
from 0.8939 to 0.9758, so equal total coverage does not establish equal pixels.
This isolates native smoothing as a major source of the default-rendering gap,
with residual rasterization and positioning differences still present.

Simple outline expansion also falls short: the best observed overlap is 0.9449.
No diagnostic variant has been applied to production. A replacement must account
for native smoothing and preserve shaping, mixed-font runs, tracking, wrapping,
alignment, fractional sizes and text colors. Existing thresholds and golden
baselines remain unchanged.

## Local evidence

- `.build/evidence/text-hinting-probe.cpp`: isolated executable source.
- `.build/evidence/text-hinting-probe.log`: font metrics and layout measurements.
- `.build/evidence/text-hinting-probe/`: 153 variant PNGs and extracted native images.
- `.build/evidence/text-hinting-comparison.json`: all comparisons, coverage values
  and SHA-256 identifiers for the native capture and probe source.
- `.build/evidence/upstream-format18-hsl-boundary-native/coregraphics-reference.json`:
  native metrics, font provenance and the five rendering variants.

The probe builds against Qt 6 Gui in the existing Linux dependency SDK. Evidence
validation checks capture hashes, verifies native alpha equality with the corpus,
and verifies default Qt alpha equality with the current Linux corpus before
reporting the experimental variants. These are diagnostic checks; they do not
constitute a passing application parity run.
