#!/bin/sh
# Builds the pinned OpenEXR (with its Imath and libdeflate) for the dev loop into build/openexr/install — the same
# options as the Flatpak manifest's `libdeflate`, `imath` and `openexr` modules: static, PIC, -O2, no tools, no tests,
# no examples, no downloads (OPENEXR_FORCE_INTERNAL_DEFLATE off: libdeflate is built here first).
# Compat ImageIO reads and writes EXR through it (host/QtImageIO.cpp), as Apple's ImageIO does on the Mac.
# Run inside the KDE SDK:
#   flatpak run --command=bash --devel --filesystem=host --share=network org.kde.Sdk//6.11 scripts/build-openexr.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/openexr"
PREFIX="$WORK/install"
mkdir -p "$WORK"
cd "$WORK"

fetch() {   # name url sha256
    if [ ! -f "$1" ]; then curl -sSLo "$1" "$2"; fi
    echo "$3  $1" | sha256sum -c -
}
fetch libdeflate-v1.26.tar.gz https://github.com/ebiggers/libdeflate/archive/refs/tags/v1.26.tar.gz \
    bba03fffc5538576213675ce6968fcff6ce2e67d82e4d5febea2d05f9f13cf85
fetch Imath-v3.2.3.tar.gz https://github.com/AcademySoftwareFoundation/Imath/archive/refs/tags/v3.2.3.tar.gz \
    e10c12b3f21f45bf08e09d4215d9c7691368d747beebd840de0b6fefed2df9f8
fetch openexr-v3.5.1.tar.gz https://github.com/AcademySoftwareFoundation/openexr/archive/refs/tags/v3.5.1.tar.gz \
    61559d6d0657f228f8dd5e3165ed6b74437b95e81849ad41c6d3493c0c144c1d

COMMON="-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF"

rm -rf libdeflate-1.26 && tar -xzf libdeflate-v1.26.tar.gz
cmake -S libdeflate-1.26 -B libdeflate-1.26/_build $COMMON -DLIBDEFLATE_BUILD_SHARED_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF
cmake --build libdeflate-1.26/_build --parallel && cmake --install libdeflate-1.26/_build

rm -rf Imath-3.2.3 && tar -xzf Imath-v3.2.3.tar.gz
cmake -S Imath-3.2.3 -B Imath-3.2.3/_build $COMMON -DBUILD_TESTING=OFF -DPYTHON=OFF
cmake --build Imath-3.2.3/_build --parallel && cmake --install Imath-3.2.3/_build

rm -rf openexr-3.5.1 && tar -xzf openexr-v3.5.1.tar.gz
cmake -S openexr-3.5.1 -B openexr-3.5.1/_build $COMMON -DBUILD_TESTING=OFF -DOPENEXR_BUILD_TOOLS=OFF \
    -DOPENEXR_BUILD_EXAMPLES=OFF -DOPENEXR_INSTALL_EXAMPLES=OFF -DOPENEXR_INSTALL_TOOLS=OFF -DOPENEXR_BUILD_PYTHON=OFF \
    -DOPENEXR_FORCE_INTERNAL_DEFLATE=OFF -DOPENEXR_FORCE_INTERNAL_IMATH=OFF -DOPENEXR_INSTALL_DOCS=OFF
cmake --build openexr-3.5.1/_build --parallel && cmake --install openexr-3.5.1/_build
echo "OpenEXR installed in $PREFIX"
