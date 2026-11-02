#!/bin/sh
# Build the same PDF backend dependency as the Flatpak manifest, entirely inside the project's build directory.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/poppler"
VERSION=26.10.0
SHA256=6792cb7c69205007ad87d2e936cecc5b3a31fac29ab54ffc3175fdb6b2a6ce35
mkdir -p "$WORK"
if [ ! -f "$WORK/poppler-$VERSION.tar.xz" ]; then
    curl --fail --location --silent --show-error "https://poppler.freedesktop.org/poppler-$VERSION.tar.xz" -o "$WORK/poppler-$VERSION.tar.xz"
fi
echo "$SHA256  $WORK/poppler-$VERSION.tar.xz" | sha256sum -c -
if [ ! -d "$WORK/poppler-$VERSION" ]; then tar -xf "$WORK/poppler-$VERSION.tar.xz" -C "$WORK"; fi
cmake -S "$WORK/poppler-$VERSION" -B "$WORK/cmake" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$WORK/install" -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=ON \
    -DENABLE_QT5=OFF -DENABLE_QT6=ON -DENABLE_CPP=OFF -DENABLE_GLIB=OFF -DENABLE_GOBJECT_INTROSPECTION=OFF \
    -DENABLE_UTILS=OFF -DBUILD_MANUAL_TESTS=OFF -DBUILD_QT6_TESTS=OFF -DENABLE_BOOST=OFF \
    -DENABLE_NSS3=OFF -DENABLE_GPGME=OFF -DENABLE_LIBCURL=OFF
cmake --build "$WORK/cmake" --parallel "${COMPOSITOR_BUILD_JOBS:-6}"
cmake --install "$WORK/cmake"
DATA_VERSION=0.4.12
DATA_SHA256=c835b640a40ce357e1b83666aabd95edffa24ddddd49b8daff63adb851cdab74
if [ ! -f "$WORK/poppler-data-$DATA_VERSION.tar.gz" ]; then
    curl --fail --location --silent --show-error "https://poppler.freedesktop.org/poppler-data-$DATA_VERSION.tar.gz" -o "$WORK/poppler-data-$DATA_VERSION.tar.gz"
fi
echo "$DATA_SHA256  $WORK/poppler-data-$DATA_VERSION.tar.gz" | sha256sum -c -
if [ ! -d "$WORK/poppler-data-$DATA_VERSION" ]; then tar -xf "$WORK/poppler-data-$DATA_VERSION.tar.gz" -C "$WORK"; fi
make -C "$WORK/poppler-data-$DATA_VERSION" install prefix="$WORK/install"
