"""Regenerate independent source metadata with psd-tools==1.10.9 (not a test dependency)."""
import hashlib
import json
from pathlib import Path

from psd_tools import PSDImage


ROOT = Path(__file__).parent
REVISION = "8f9a25ea98202061365701db54ce938931b27c09"
result = {"repository": "https://github.com/psd-tools/psd-tools", "revision": REVISION,
          "inspector": "psd-tools==1.10.9", "fixtures": {}}
for path in sorted(ROOT.glob("*.psd")):
    document = PSDImage.open(path)
    # The .comp flat list places a group's marker after its bottom-to-top children.
    def flatten(container):
        for layer in container:
            if layer.is_group():
                yield from flatten(layer)
            yield layer
    layers = list(flatten(document))
    source_path = "tests/psd_files/" + ("adjustments/" if path.name.startswith("adjustment_nested") else "") + path.name
    records = []
    for layer in layers:
        records.append({"name": layer.name, "kind": layer.kind, "visible": layer.visible,
                        "opacity": layer.opacity / 255, "blend": layer.blend_mode.value.decode("ascii"),
                        "group": layer.is_group(), "parent": layers.index(layer.parent) if layer.parent is not document else None,
                        "mask": layer.has_mask(),
                        "raster_mask": layer.has_mask() and min(layer.mask.size) > 0 and not layer.mask._data.flags.user_mask_from_render,
                        "clipped": bool(layer._record.clipping),
                        "bounds": list(layer.bbox)})
    result["fixtures"][path.name] = {
        "url": f"https://raw.githubusercontent.com/psd-tools/psd-tools/{REVISION}/{source_path}",
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size,
        "width": document.width, "height": document.height, "depth": document.depth, "layers": records}
    if path.name == "hidden-groups.psd":
        # Photoshop's embedded merged image, not a recomposite by either importer.
        document.topil().save(ROOT / "hidden-groups-merged.png")
(ROOT / "manifest.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
