"""El bundle del Steam Frame debe llevar TODO lo que necesita la ruta: viewer (route/, world.gd, shader) y route-planner/."""
import os, subprocess, tarfile, tempfile
import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def test_make_bundle_incluye_planificador_y_visor():
    with tempfile.TemporaryDirectory() as out:
        open(os.path.join(out, "Godot_v4.7.2-stable_linux.arm64"), "w").write("x")     # evita la descarga de 138 MB
        subprocess.run(["bash", os.path.join(ROOT, "tools/frame/make_bundle.sh"), out], cwd=ROOT, check=True, capture_output=True)
        names = tarfile.open(os.path.join(out, "mars-frame-bundle.tgz")).getnames()
    for need in ("mars-route-walker/route-planner/mars_route.py", "mars-route-walker/route-planner/geo.py",
                 "mars-route-walker/viewer-godot/route/route_ui.gd", "mars-route-walker/viewer-godot/route/guide_path.gd",
                 "mars-route-walker/viewer-godot/world.gd", "mars-route-walker/viewer-godot/terrain.gdshader"):
        assert need in names, "falta en el bundle: " + need


def test_install_prepara_python_del_planificador():
    s = open(os.path.join(ROOT, "tools/frame/install.sh")).read()
    assert "python3 -m venv .venv" in s and "numpy pillow" in s
