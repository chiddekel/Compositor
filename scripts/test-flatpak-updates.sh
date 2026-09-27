#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/compositor-updater-tests.XXXXXX)
bus_pid=
trap 'if [[ -n "$bus_pid" ]]; then kill "$bus_pid"; fi; rm -rf "$build_dir"' EXIT
bus_pid=$(dbus-daemon --session --fork --address="unix:path=$build_dir/bus" --print-pid=1)
sdk=$(sed -n "s/^runtime-version: *['\"]\?\([0-9.]*\)['\"]\?.*/\1/p" com.compositor.Client.yaml)
flatpak run --command=bash --devel --filesystem="$PWD" --filesystem="$build_dir" \
  --env=COMPOSITOR_TEST_DBUS_ADDRESS="unix:path=$build_dir/bus" "org.kde.Sdk//$sdk" -c '
  set -euo pipefail
  cd "$1"
  output=$2
  moc=$(pkg-config --variable=libexecdir Qt6Core)/moc
  "$moc" host/FlatpakUpdateService.h -o "$output/moc_FlatpakUpdateService.cpp"
  "$moc" tests/test_flatpak_updates.cpp -o "$output/test_flatpak_updates.moc"
  c++ -std=c++17 -fPIC -Ihost -I"$output" $(pkg-config --cflags Qt6Widgets Qt6DBus) \
    tests/test_flatpak_updates.cpp host/FlatpakUpdateService.cpp "$output/moc_FlatpakUpdateService.cpp" \
    $(pkg-config --libs Qt6Widgets Qt6DBus) -o "$output/test-updater"
  QT_QPA_PLATFORM=offscreen "$output/test-updater"
' tests "$PWD" "$build_dir"
