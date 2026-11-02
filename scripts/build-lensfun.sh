#!/bin/sh
# Builds the pinned lensfun (lens database and its library: distortion, chromatic aberration and vignetting profiles
# by camera and lens) for the dev loop into build/lensfun/install — the same options as the Flatpak manifest's
# `lensfun` module: static library, PIC, no tools, tests, docs or Python. Run inside the KDE SDK:
#   flatpak run --command=bash --devel --filesystem=host --share=network org.kde.Sdk//6.11 scripts/build-lensfun.sh
set -e
VERSION=0.3.4
SHA256=dafb39c08ef24a0e2abd00d05d7341b1bf1f0c38bfcd5a4c69cf5f0ecb6db112
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/lensfun"
mkdir -p "$WORK"
cd "$WORK"
if [ ! -f "lensfun-$VERSION.tar.gz" ]; then
    curl -sSLo "lensfun-$VERSION.tar.gz" "https://github.com/lensfun/lensfun/archive/refs/tags/v$VERSION.tar.gz"
fi
echo "$SHA256  lensfun-$VERSION.tar.gz" | sha256sum -c -
rm -rf "lensfun-$VERSION" build
tar -xzf "lensfun-$VERSION.tar.gz"
cmake -S "lensfun-$VERSION" -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WORK/install" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_STATIC=ON -DBUILD_TESTS=OFF -DBUILD_LENSTOOL=OFF -DBUILD_DOC=OFF \
    -DINSTALL_HELPER_SCRIPTS=OFF -DINSTALL_PYTHON_MODULE=OFF -DBUILD_FOR_SSE=ON -DBUILD_FOR_SSE2=ON
cmake --build build
cmake --install build
