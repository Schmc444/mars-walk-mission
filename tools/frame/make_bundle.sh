#!/bin/bash
# Builds mars-frame-bundle.tgz (Godot arm64 + viewer + install.sh) for the Steam Frame. Run from the repo root.
# The Godot binary is downloaded, not committed (138 MB, over GitHub's file limit).
set -e
GV=4.7.2-stable
OUT=${1:-$PWD/frame-bundle}
mkdir -p "$OUT" && cd "$OUT"
[ -f Godot_v${GV}_linux.arm64 ] || { curl -sL -o g.zip https://github.com/godotengine/godot-builds/releases/download/$GV/Godot_v${GV}_linux.arm64.zip && unzip -oq g.zip && rm g.zip; }
git -C "$OLDPWD" archive --format=tar --prefix=mars-route-walker/ HEAD viewer-godot | tar -x
cp "$OLDPWD/tools/frame/install.sh" .
tar czf mars-frame-bundle.tgz install.sh Godot_v${GV}_linux.arm64 mars-route-walker
echo "$OUT/mars-frame-bundle.tgz"
