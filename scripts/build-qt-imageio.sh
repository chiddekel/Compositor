#!/usr/bin/env bash
# build-qt-imageio.sh — rebuilds build/lib/libCompositorQtImageIO.so (host/QtImageIO.cpp: Qt codecs, text engine, SVG,
# font metrics) inside the KDE SDK. The Swift build does not produce it; the compat layer dlopens it at run time, so a
# change to host/QtImageIO.cpp needs this (the Flatpak build compiles it through CMake).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/build/lib"
flatpak run --command=bash --devel --filesystem=host org.kde.Sdk//6.11 -c "
  set -e
  cd '$ROOT'
  HEIF=''
  if pkg-config --exists libheif; then HEIF=\"-DCOMPOSITOR_HAS_LIBHEIF \$(pkg-config --cflags --libs libheif)\"; fi
  c++ -std=c++17 -O2 -fPIC -shared host/QtImageIO.cpp -o build/lib/libCompositorQtImageIO.so.new \
    \$(pkg-config --cflags --libs Qt6Gui) \$HEIF
  mv build/lib/libCompositorQtImageIO.so.new build/lib/libCompositorQtImageIO.so
"
echo "built $ROOT/build/lib/libCompositorQtImageIO.so"
