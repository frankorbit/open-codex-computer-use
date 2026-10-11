#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != "--move-pointer" ]]; then
  echo 'Usage: scripts/test-preview-hover.sh --move-pointer (moves and restores the physical pointer)'
  exit 2
fi
swift build --product OpenComputerUse
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/ocu-preview-hover.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT
swiftc -parse-as-library -swift-version 6 \
  -I .build/out/Products/Debug \
  -Xcc -fmodule-map-file=.build/out/Intermediates.noindex/GeneratedModuleMaps/OpenComputerUseVirtualDisplayShim.modulemap \
  -Xcc -fmodule-map-file=.build/out/Intermediates.noindex/GeneratedModuleMaps/libwebp.modulemap \
  scripts/fixtures/preview-hover.swift \
  .build/out/Products/Debug/OpenComputerUseKit.o \
  .build/out/Products/Debug/OpenComputerUseVirtualDisplayShim.o \
  .build/out/Products/Debug/libwebp.o -o "$probe_dir/PreviewHoverProbe"
"$probe_dir/PreviewHoverProbe" --move-pointer
