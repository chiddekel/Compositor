#!/usr/bin/env bash
# build-opencv.sh — the pinned OpenCV (4.14.0) as the Flatpak manifest builds it, into build/opencv/install, for local
# development: static core + imgproc (layer effects) + dnn (U²-Net subject segmentation, backends/vision).
# Needs build/downloads/opencv-4.14.0.tar.gz (the manifest's archive, same sha256). Runs inside the KDE SDK.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="$ROOT/build/downloads/opencv-4.14.0.tar.gz"
SHA256=ee8fb9b30eb60850431b4656447080e3737b56e45719c92b67f245950609f86e
[[ -f "$ARCHIVE" ]] || { echo "missing $ARCHIVE — download https://github.com/opencv/opencv/archive/refs/tags/4.14.0.tar.gz" >&2; exit 1; }
echo "$SHA256  $ARCHIVE" | sha256sum -c -
SRC="$ROOT/build/opencv/src"
rm -rf "$SRC" && mkdir -p "$SRC" && tar -xzf "$ARCHIVE" -C "$SRC" --strip-components=1
flatpak run --command=bash --devel --filesystem=host org.kde.Sdk//6.11 -c "
  set -e
  cmake -S '$SRC' -B '$ROOT/build/opencv/build' -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LIST=core,imgproc,dnn -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF \
    -DBUILD_PERF_TESTS=OFF -DBUILD_opencv_python2=OFF -DBUILD_opencv_python3=OFF -DBUILD_ZLIB=ON -DBUILD_PNG=OFF \
    -DWITH_PNG=OFF -DBUILD_JPEG=ON -DBUILD_TIFF=OFF -DBUILD_WEBP=OFF -DBUILD_OPENJPEG=OFF -DBUILD_OPENEXR=OFF \
    -DWITH_TIFF=OFF -DWITH_WEBP=OFF -DWITH_OPENJPEG=OFF -DWITH_JASPER=OFF -DBUILD_JASPER=OFF -DWITH_OPENEXR=OFF \
    -DWITH_V4L=OFF -DWITH_GTK=OFF -DWITH_GSTREAMER=OFF -DWITH_FFMPEG=OFF -DWITH_LAPACK=OFF -DWITH_IPP=OFF \
    -DWITH_ITT=OFF -DWITH_EIGEN=OFF -DWITH_OPENCL=OFF \
    -DWITH_PROTOBUF=ON -DBUILD_PROTOBUF=ON -DOPENCV_DNN_OPENCL=OFF -DWITH_OPENVINO=OFF -DWITH_FLATBUFFERS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX='$ROOT/build/opencv/install'
  cmake --build '$ROOT/build/opencv/build'
  cmake --install '$ROOT/build/opencv/build'
"
echo "OpenCV (core, imgproc, dnn) installed in $ROOT/build/opencv/install"
