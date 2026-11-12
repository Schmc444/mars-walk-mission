#!/bin/bash
# Run on the Steam Frame (arm64) from the unpacked bundle dir. Installs to ~/mars (home only, rootfs untouched).
set -e
cd "$(dirname "$0")"
D=$HOME/mars
mkdir -p $D
rm -rf $D/mars-route-walker
cp -r mars-route-walker $D/
install -m755 Godot_v4.7.2-stable_linux.arm64 $D/godot
cd $D/mars-route-walker/viewer-godot
$D/godot --headless --import --path . 2>&1 | tail -3
cat > $D/mars-flat.sh <<L
#!/bin/bash
cd $D/mars-route-walker/viewer-godot && exec $D/godot --xr-mode off --path . -- --patch=patch_793 "\$@"
L
cat > $D/mars-xr.sh <<L
#!/bin/bash
cd $D/mars-route-walker/viewer-godot && exec $D/godot --xr-mode on --path . -- --patch=patch_793 "\$@"
L
chmod +x $D/mars-*.sh
echo "OK. Test: $D/mars-flat.sh   (VR: $D/mars-xr.sh)"
