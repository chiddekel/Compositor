#!/bin/sh
# Optional: RawSpeed (darktable's RAW decoder) for LibRaw's RawSpeed-v3 path — faster unpacking of many compressed RAW
# formats. LibRaw supports exactly one RawSpeed commit, patched with the fixes it ships in RawSpeed3/patches; this
# builds that commit (static, PIC, no OpenMP as LibRaw recommends, no tests/tools), pugixml for its camera list, and
# LibRaw's C wrapper with cameras.xml compiled in, into build/rawspeed/install. scripts/build-libraw.sh then builds
# LibRaw against it when it is there. At run time COMPOSITOR_RAWSPEED=0 turns it off (LibRaw's own decoders only).
# Run inside the KDE SDK, after scripts/build-libraw.sh has unpacked LibRaw:
#   flatpak run --command=bash --devel --filesystem=host --share=network org.kde.Sdk//6.11 scripts/build-rawspeed.sh
set -e
COMMIT=de70ef5fbc62cde91009c8cff7a206272abe631e
SHA256=993d5e6498d838c10d49aafa193a8ec46307be2b7554a81d31cfc21f3c2726e8
PUGIXML=1.14
PUGIXML_SHA256=2f10e276870c64b1db6809050a75e11a897a8d7456c4be5c6b2e35a11168a015
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBRAW_SRC="$ROOT/build/libraw/LibRaw-0.22.2"
WORK="$ROOT/build/rawspeed"
PREFIX="$WORK/install"
[ -d "$LIBRAW_SRC/RawSpeed3" ] || { echo "run scripts/build-libraw.sh first (needs LibRaw's RawSpeed3 folder)"; exit 1; }
mkdir -p "$WORK"
cd "$WORK"
[ -f rawspeed.tar.gz ] || curl -sSLo rawspeed.tar.gz "https://github.com/darktable-org/rawspeed/archive/$COMMIT.tar.gz"
[ -f "pugixml-$PUGIXML.tar.gz" ] || curl -sSLo "pugixml-$PUGIXML.tar.gz" "https://github.com/zeux/pugixml/releases/download/v$PUGIXML/pugixml-$PUGIXML.tar.gz"
echo "$SHA256  rawspeed.tar.gz" | sha256sum -c -
echo "$PUGIXML_SHA256  pugixml-$PUGIXML.tar.gz" | sha256sum -c -
rm -rf "rawspeed-$COMMIT" "pugixml-$PUGIXML" build "$PREFIX"
tar -xzf rawspeed.tar.gz
tar -xzf "pugixml-$PUGIXML.tar.gz"
# LibRaw's fixes. 01 (drop `final` from CameraMetaData, so the wrapper can load cameras.xml from memory) is stored
# reversed in LibRaw's tree, so it is applied with -R.
patch -d "rawspeed-$COMMIT" -p1 -R < "$LIBRAW_SRC/RawSpeed3/patches/01.CameraMeta-extensibility.patch"
for patch in "$LIBRAW_SRC"/RawSpeed3/patches/0[2-5]*.patch; do
    patch -d "rawspeed-$COMMIT" -p1 --forward < "$patch"
done

# pugixml (static, PIC).
cmake -S "pugixml-$PUGIXML" -B build/pugixml -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
cmake --build build/pugixml
cmake --install build/pugixml

# RawSpeed itself.
cmake -S "rawspeed-$COMMIT" -B build/rawspeed -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DBUILD_TESTING=OFF -DBUILD_TOOLS=OFF -DBUILD_BENCHMARKING=OFF -DBUILD_FUZZERS=OFF -DBUILD_DOCS=OFF \
    -DWITH_OPENMP=OFF -DRAWSPEED_ENABLE_WERROR=OFF -DRAWSPEED_ENABLE_DEBUG_INFO=OFF -DUSE_XMLLINT=OFF \
    -DBINARY_PACKAGE_BUILD=ON -DWITH_PUGIXML=ON -DWITH_JPEG=ON -DWITH_ZLIB=ON
cmake --build build/rawspeed --target rawspeed

# LibRaw's C wrapper, with cameras.xml compiled in.
CAPI="$LIBRAW_SRC/RawSpeed3/rawspeed3_c_api"
mkdir -p "$PREFIX/lib" "$PREFIX/include" "$PREFIX/pugixml" build/capi
cp "$PREFIX"/include/pugi*.hpp "$PREFIX/pugixml/"   # the wrapper includes <../pugixml/pugixml.hpp>
sh "$CAPI/rsxml2c.sh" < "rawspeed-$COMMIT/data/cameras.xml" > build/capi/cameras.cpp
RS_INCLUDES="-I rawspeed-$COMMIT/src/librawspeed -I rawspeed-$COMMIT/src/external -I build/rawspeed/src -I build/rawspeed -I $PREFIX/include"
for src in "$CAPI/rawspeed3_capi.cpp" build/capi/cameras.cpp; do
    g++ -std=c++17 -O3 -fPIC -DNDEBUG $RS_INCLUDES -c "$src" -o "build/capi/$(basename "$src" .cpp).o"
done
ar rcs "$PREFIX/lib/librawspeed3_capi.a" build/capi/rawspeed3_capi.o build/capi/cameras.o
cp "$CAPI/rawspeed3_capi.h" "$PREFIX/include/"
find build/rawspeed -name 'librawspeed*.a' -exec cp {} "$PREFIX/lib/" \;
ls -la "$PREFIX/lib"
