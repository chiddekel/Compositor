#!/usr/bin/env python3
"""Check Qt dialog export fixtures through installed Poppler and Pillow/LittleCMS.

Run the native Color Picker journey with COMPOSITOR_EXPORT_MATTE_ARTIFACTS set
to a directory, then pass that directory here. No extra app implementation is used.
"""

import argparse
import io
from pathlib import Path
import subprocess

from PIL import Image, ImageChops, ImageCms
from pypdf import PdfReader


def maximum_difference(actual, expected):
    assert actual.size == expected.size, (actual.size, expected.size)
    assert actual.mode == expected.mode, (actual.mode, expected.mode)
    return max(high for _, high in ImageChops.difference(actual, expected).getextrema())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path)
    args = parser.parse_args()
    root = args.artifacts
    expected = Image.open(root / "matte-expected.png").convert("RGB")
    assert expected.size == (64, 64), expected.size
    assert expected.getpixel((0, 0)) == (0, 255, 0)

    reader = PdfReader(root / "matte.pdf")
    assert len(reader.pages) == 1
    page = reader.pages[0]
    operations = page.get_contents().operations
    assert any(operator == b"rg" and tuple(map(float, values)) == (0, 1, 0)
               for values, operator in operations), "PDF does not paint the chosen green matte"
    assert any(operator == b"re" and tuple(map(float, values)) == (0, 0, 64, 64)
               for values, operator in operations), "PDF matte does not cover the page"
    resource = page["/Resources"]["/XObject"]["/Im0"].get_object()
    assert resource["/ColorSpace"] == "/DeviceRGB"
    rgb = Image.frombytes("RGB", (64, 64), resource.get_data())
    mask = Image.frombytes("L", (64, 64), resource["/SMask"].get_data())
    assembled = Image.composite(rgb, Image.new("RGB", (64, 64), (0, 255, 0)), mask)
    assert maximum_difference(assembled, expected) == 0, "PDF image/mask source pixels changed"
    print("PASS: PDF lossless image/mask, page matte, all 4096 composed RGB pixels exact")

    subprocess.run(
        ["pdftoppm", "-singlefile", "-png", "-scale-to-x", "64", "-scale-to-y", "64",
         str(root / "matte.pdf"), str(root / "matte-pdf-rendered")],
        check=True,
    )
    rendered = Image.open(root / "matte-pdf-rendered.png").convert("RGB")
    assert rendered.size == expected.size
    # Poppler interpolates image/mask transitions at a pixel boundary. Check the
    # remaining interior/exterior here; the resource comparison above covers every pixel exactly.
    pdf_delta = max(abs(a - b)
                    for y in range(64) for x in range(64)
                    if x not in (7, 8, 55, 56) and y not in (7, 8, 55, 56)
                    for a, b in zip(rendered.getpixel((x, y)), expected.getpixel((x, y))))
    # One source-pixel resampling phase is bounded by this fixture's measured ramp step.
    ramp_step = max(abs(expected.getpixel((x + 1, 32))[0] - expected.getpixel((x, 32))[0])
                    for x in range(10, 53))
    assert pdf_delta <= ramp_step, f"PDF matte/source RGB differs by {pdf_delta}/255, ramp step {ramp_step}"
    for xy in ((0, 0), (63, 0), (0, 63), (63, 63)):
        assert rendered.getpixel(xy) == (0, 255, 0), "PDF page matte rendered incorrectly"
    print(f"PASS: PDF Poppler interior/exterior rendering, max delta {pdf_delta}/255 <= ramp step {ramp_step}; transition band excluded")

    ink = Image.open(root / "matte-cmyk.tiff")
    assert ink.mode == "CMYK", ink.mode
    assert ink.tag_v2[262] == 5, "TIFF is not separated ink"
    assert ink.tag_v2[277] == 4, "TIFF does not have four ink channels"
    profile_data = ink.info.get("icc_profile")
    assert profile_data and profile_data[16:20] == b"CMYK", "CMYK ICC profile missing"
    profile = ImageCms.ImageCmsProfile(io.BytesIO(profile_data))
    oracle = ImageCms.profileToProfile(
        expected, ImageCms.createProfile("sRGB"), profile,
        renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC, outputMode="CMYK",
    )
    ink_delta = maximum_difference(ink, oracle)
    assert ink_delta <= 2, f"TIFF matte/source CMYK differs by {ink_delta}/255"
    print(f"PASS: CMYK TIFF, embedded ICC, all 4096 ink pixels, max delta {ink_delta}/255")


if __name__ == "__main__":
    main()
