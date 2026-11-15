"""Pruebas en Godot headless (se saltan si no hay `godot` en el PATH): precisión de GuidePath y selftest del modo parche."""
import os, shutil, subprocess
import pytest

ROOT = os.path.join(os.path.dirname(__file__), "..")
godot = shutil.which("godot")
pytestmark = pytest.mark.skipif(godot is None, reason="godot no está en el PATH")


def _run(args, timeout=300):
    p = subprocess.run([godot, "--headless", "--path", os.path.join(ROOT, "viewer-godot")] + args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr


def test_guia_precision():
    code, out = _run(["--script", "res://route/test_guide.gd"])
    assert "RESULTADO: TODO OK" in out and code == 0, out[-1500:]


def test_selftest_parche():
    code, out = _run(["--script", "res://route/selftest.gd", "--", "--patch=patch_793"], 600)
    assert "RESULTADO: TODO OK" in out and code == 0, "\n".join(l for l in out.splitlines() if l.startswith("FALLO"))
