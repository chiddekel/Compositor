#!/bin/sh
# Builds the pinned LibRaw (camera RAW decoding) for the dev loop into build/libraw/install — the same options as the
# Flatpak manifest's `libraw` module: static, PIC, OpenMP (multithreaded demosaic), -O3, no JasPer/LCMS, no examples.
# Run inside the KDE SDK (it has the toolchain and zlib):
#   flatpak run --command=bash --devel --filesystem=host --share=network org.kde.Sdk//6.11 scripts/build-libraw.sh
set -e
VERSION=0.22.2
SHA256=de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/libraw"
mkdir -p "$WORK"
cd "$WORK"
if [ ! -f "LibRaw-$VERSION.tar.gz" ]; then
    curl -sSLo "LibRaw-$VERSION.tar.gz" "https://www.libraw.org/data/LibRaw-$VERSION.tar.gz"
fi
echo "$SHA256  LibRaw-$VERSION.tar.gz" | sha256sum -c -
rm -rf "LibRaw-$VERSION"
tar -xzf "LibRaw-$VERSION.tar.gz"
cd "LibRaw-$VERSION"
CFLAGS="-O3 -fPIC" CXXFLAGS="-O3 -fPIC" ./configure --prefix="$WORK/install" --enable-static --disable-shared \
    --enable-openmp --disable-examples --disable-jasper --disable-lcms --enable-zlib
make -j"$(nproc)"
make install
ls -la "$WORK/install/lib/libraw_r.a"
