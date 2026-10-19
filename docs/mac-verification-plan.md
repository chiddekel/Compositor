# Verifying against macOS (T-10, T-18, T-23)

Three checks need a Mac running upstream Compositor. The Linux side of each is scripted. The Mac side is ordinary
use of the app: no Xcode, no changes to the Mac sources or their project. Any Apple-silicon or Intel Mac on
macOS 15 or later with upstream Compositor 1.5.3 (the release GNU_Linux tracks) will do: a borrowed machine, or a
rented one (MacStadium, AWS EC2 Mac, Scaleway Apple silicon). A GitHub-hosted macOS runner works for nothing here,
because every step needs the app's interface.

Record for each run: Mac model, macOS version, Compositor version (About), and the Linux commit and Flatpak version.
Keep everything that goes back and forth under `.build/evidence/mac/<date>/`.

Linux commands below use the release build, `B=.build/evidence/swift-build/x86_64-unknown-linux-gnu/release/CompositorHostBootstrap`,
run inside the SDK with the contract environment (`.build/evidence/env.sh`), or the installed app through
`flatpak run --command=compositor com.compositor.Client …`.

## T-10: `.comp` documents both ways (closes GAP-VER-04 for documents)

The tool is `--interchange` (`host/InterchangeJourney.cpp`), described step by step in
`linux/interchange-verification.md`. It compares manifests field by field, and decoded layer and mask pixels at
≤ 1/255 (masks exact).

1. **Linux → Mac → Linux.** On Linux: `$B --interchange fixture <dir>` makes `original.comp` and its reference PNG.
   On the Mac: open `original.comp`, export `mac-unedited.png`, then Save As `mac-unedited.comp`. Back on Linux:
   `$B --interchange verify <dir>/original.comp mac-unedited.comp <dir>/linux-reference.png mac-unedited.png`.
2. **Mac → Linux → Mac.** On the Mac, build the corpus below and save each as a project. On Linux, for each one:
   `$B --interchange roundtrip mac/<name>.comp linux/<name>.comp`. That opens it, saves it through the Linux
   writer, exports a PNG and compares. Then open every `linux/<name>.comp` on the Mac, export a PNG, and compare the
   Mac's before and after with `--interchange verify`.
3. **The corpus to make on the Mac.** One project per item:
   - an old project for each format version you can still find (1–13), opened and saved again;
   - a 16-bit PNG layer and an EXR (HDR) layer;
   - masks: linked, unlinked and moved;
   - a clipping stack, and nested folders with opacity and a folder mask;
   - every adjustment kind as adjustment layers;
   - every layer effect;
   - live text with per-letter font and color; live shapes with smooth corners;
   - guides, and grid settings;
   - a CMYK PSD opened and saved.

Pass: every `verify` and `roundtrip` exits 0. Text may reflow if a font is missing on one side, so record the fonts.

## T-23: golden images (closes GAP-VER-04 for rendering)

Use the T-10 corpus, plus one project per row of report 07's table (blend modes, adjustments, filters, effects,
transform sampling, text, RAW, export formats). For each project:

1. On the Mac: File › Export As… PNG (and JPEG, PDF, EXR or CMYK TIFF for the export row). Name it
   `<project>.mac.png`.
2. On Linux: open the same `.comp`, export `<project>.linux.png` (or run `$B --interchange roundtrip`, which
   exports one for you).
3. Compare with `$B --interchange verify <a>.comp <b>.comp <a>.png <b>.png`, which gives the maximum channel error.
   For rows whose tolerance is perceptual (ΔE2000, SSIM, glyph IoU), compare the two PNGs with any ΔE2000 tool
   (for example `python3 -m colour` or ImageMagick `compare -metric`) against report 07's tolerances.

Expected and accepted differences, to be written down rather than fixed: RAW look (LibRaw against Apple's engine),
glyph edges (Qt against Core Text) within glyph IoU 0.97, and subject masks (see T-18). Anything else outside its
tolerance is a Linux bug: file it with the two PNGs.

## T-18: subject masks (GAP-PLAT-01)

Linux uses U²-Net-small; the Mac uses Apple Vision. This measures how far apart they are on real photos.

1. Choose 30 or more photos of varied subjects: people with loose hair, pets, objects on busy backgrounds, low
   contrast, several subjects at once. Use JPEG or PNG without EXIF rotation, or rotate them first.
2. **Mac.** For each photo: open it (a new document from the file), choose Layer › Remove Background, then save the
   project as `<photo name>.comp` (same name as the photo). Its `<layer id>.mask.png` is the Mac's mask.
3. **Linux.** `$B --subject-masks <photos> <linux-masks>` writes `<photo name>.mask.png` for each photo, using the
   same upstream code path (`SubjectRemoval.subjectMask`) with the shipped model.
4. **Score.** `scripts/compare-subject-masks.py <linux-masks> <mac-projects>` prints, for each photo, IoU, mean
   difference and edge disagreement. It passes when the median IoU is at least 0.90 and no photo falls below 0.50.
   Pass `--min-iou` to change the threshold.
5. If it fails, the worst photos show where the model differs. The remedies, in order: tune the refinement
   threshold and edge feathering in `Sources/LinuxBridge/SubjectSegmentation.swift` (upstream's `refined` step stays
   as it is), then try the full U²-Net or a newer matting model behind the same seam.
