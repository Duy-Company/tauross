#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/Tauross.iconset .build/ModuleCache
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift Scripts/make-icon.swift build/icon-master.png
for pixels in 16 32 128 256 512; do
  sips -z "$pixels" "$pixels" build/icon-master.png --out "build/Tauross.iconset/icon_${pixels}x${pixels}.png" > /dev/null
  doubled=$((pixels * 2))
  sips -z "$doubled" "$doubled" build/icon-master.png --out "build/Tauross.iconset/icon_${pixels}x${pixels}@2x.png" > /dev/null
done
iconutil -c icns build/Tauross.iconset -o Tauross/Resources/Tauross.icns
