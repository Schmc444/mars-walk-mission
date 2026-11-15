#!/bin/bash
# Run on the Steam Frame (arm64) from the unpacked bundle dir. Installs to ~/mars (home only, rootfs untouched).
set -e
cd "$(dirname "$0")"
D=$HOME/mars
mkdir -p $D
rm -rf $D/mars-route-walker
cp -r mars-route-walker $D/
install -m755 Godot_v4.7.2-stable_linux.arm64 $D/godot
# Planificador de rutas (Python + numpy + Pillow) en $D/mars-route-walker/.venv, que es donde route_ui.gd lo busca. Sin esto el visor
# arranca pero la tecla L/P no puede calcular rutas ("No se pudo ejecutar el planificador").
if command -v python3 >/dev/null; then
  ( cd $D/mars-route-walker && python3 -m venv .venv && .venv/bin/pip install -q numpy pillow ) \
    && echo "Planificador de rutas: OK" || echo "AVISO: no se pudo crear el venv del planificador (sin internet / sin python3-venv); copia un guide_path.json calculado en la PC"
else
  echo "AVISO: no hay python3 en el Frame; el planificador de rutas no funcionara (calcula las rutas en la PC)"
fi
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
