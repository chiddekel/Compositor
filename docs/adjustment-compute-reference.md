# Native adjustment compute reference

The manual `adjustment-compute-reference.yml` workflow captures the original Metal
shaders at upstream `7651033e0abab135db40e9375a639fae55c313ff`. It fetches that exact
commit and reads its Bokeh and dispersion shader strings into a disposable source
directory. Protected application files remain untouched. Compilation and execution
use a native macOS Metal device with the application's default compile options.
This measures kernel pixels, not application rendering or GPU performance.

The Bokeh matrix has 96 cases: two inputs, four aperture shapes, three radii, two
ring amounts, and full versus interior-tile output. A padded 168×144 input texture
supplies a 96×72 global region. The tile is `(13, 7, 48, 36)` in that region, keeping
its global Cat's Eye coordinates. Inputs contain an impulse or premultiplied HDR
ramps with negative blue values. Inputs and outputs are complete RGBA half floats.

Four RGB Split cases run the original `smear` and `spectrum` kernels in sequence,
covering linear/radial directions and two spectrum distances. Each records the
complete half-float streak texture and final RGBA8 output, including the padded
intermediate's size. The source is the existing synthetic 61×61 impulse fixture.

The validator checks the exact matrices, parameter strides, source/script hashes,
buffer lengths and hashes, finite half floats, nonempty outputs, impulse location,
and bit-identical Bokeh full/tile overlap. A synthetic gate harness checks that
missing/duplicate cases, hash corruption, nonfinite half values, wrong tile origins,
short buffers and wrong commit provenance are rejected. Those synthetic harness
results are not native pixel evidence; only the successful macOS workflow supplies
that evidence.

To validate a downloaded capture against its pinned source files:

```sh
python3 scripts/validate-adjustment-compute-reference.py adjustment-compute-reference.json \
  --source /path/to/pinned-source \
  --commit 7651033e0abab135db40e9375a639fae55c313ff
```

The capture script explicitly refuses Linux execution. It does not synthesize
reference pixels from the compatibility implementation or replace any existing
native fixture or Linux golden image.
