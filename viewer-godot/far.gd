class_name FarRings
extends Node3D
# Far-field terrain around the tiled world (made by tools/build_far.py, world/far/far.json).
# "mid": HiRISE DTM at ~12 m + CTX texture, skipped where world tiles exist. "far": HRSC/MOLA 200 m out to 80 km.
# Meshes are in world coordinates, lowered a few metres so the detailed tiles always win, bent by Mars curvature in the shader.

const SHADER_CODE := """
shader_type spatial;
uniform vec3 albedo = vec3(0.2, 0.14, 0.1);
uniform float planet_r = 3396190.0;
uniform sampler2D tex : hint_default_white, filter_linear_mipmap, repeat_disable;
uniform float tex_mean = 1.0;
uniform float tex_on = 0.0;
uniform vec4 tex_rect = vec4(0.0, 0.0, 1.0, 1.0);
varying vec2 wpos;
float h21(vec2 p){ vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vn(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
  return mix(mix(h21(i),h21(i+vec2(1,0)),f.x), mix(h21(i+vec2(0,1)),h21(i+vec2(1,1)),f.x), f.y); }
void vertex() {
  wpos = VERTEX.xz;
  vec2 rel = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz - CAMERA_POSITION_WORLD.xz;
  VERTEX.y -= dot(rel, rel) / (2.0 * planet_r);
}
void fragment() {
  float d = vn(wpos / 120.0) * 0.6 + vn(wpos / 30.0) * 0.4;
  float tv = texture(tex, (wpos - tex_rect.xy) / tex_rect.zw).r;
  float tg = mix(1.0, pow(clamp(tv / tex_mean, 0.4, 1.7), 1.25), tex_on);
  ALBEDO = albedo * (0.8 + 0.4 * d) * tg;
  ROUGHNESS = 1.0;
}
"""

var albedo := Color(0.2, 0.14, 0.1)
var planet_r := 3396190.0
var tri_count := 0


func setup(dir: String, w: WorldStreamer) -> bool:
	var d := dir if dir.ends_with("/") else dir + "/"
	var jp := d + "far/far.json"
	if not FileAccess.file_exists(jp):
		return false
	var J: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(jp))
	for r in J["rings"]:
		_ring(d + "far/", r, w)
	return true


func _covered(w: WorldStreamer, x: float, z: float) -> bool:
	var bx := int(floor(x / w.sx + w.opx)) / w.block if x / w.sx + w.opx >= 0.0 else -1
	var by := int(floor(z / w.sz + w.opy)) / w.block if z / w.sz + w.opy >= 0.0 else -1
	return w.tiles.has(Vector2i(bx, by))


func _ring(dir: String, r: Dictionary, w: WorldStreamer) -> void:
	var nx := int(r["nx"])
	var nz := int(r["nz"])
	var sub := int(r.get("subsample", 3))
	var lower := float(r.get("lower_m", 3.0))
	var f := FileAccess.open(dir + r["file"], FileAccess.READ)
	if f == null:
		return
	var hs := f.get_buffer(f.get_length()).to_float32_array()
	var x0 := float(r["x0"])
	var z0 := float(r["z0"])
	var dx := float(r["dx"]) * sub
	var dz := float(r["dz"]) * sub
	var cx := (nx - 1) / sub
	var cz := (nz - 1) / sub
	var vx := cx + 1
	var vz := cz + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	verts.resize(vx * vz)
	norms.resize(vx * vz)
	for j in range(vz):
		for i in range(vx):
			verts[j * vx + i] = Vector3(x0 + i * dx, hs[(j * sub) * nx + i * sub] - lower, z0 + j * dz)
	for j in range(vz):
		for i in range(vx):
			var hl := verts[j * vx + maxi(i - 1, 0)].y
			var hr := verts[j * vx + mini(i + 1, vx - 1)].y
			var hu := verts[maxi(j - 1, 0) * vx + i].y
			var hd := verts[mini(j + 1, vz - 1) * vx + i].y
			norms[j * vx + i] = Vector3(hl - hr, 2.0 * dx, hu - hd).normalized()
	var skip_rect: Array = r.get("skip_rect", [])
	var skip_cov: bool = r.get("skip_covered", false)
	var idx := PackedInt32Array()
	for j in range(cz):
		for i in range(cx):
			var ax := x0 + i * dx
			var az := z0 + j * dz
			if skip_rect.size() == 4 and ax >= skip_rect[0] and ax + dx <= skip_rect[0] + skip_rect[2] \
					and az >= skip_rect[1] and az + dz <= skip_rect[1] + skip_rect[3]:
				continue
			if skip_cov and _covered(w, ax, az) and _covered(w, ax + dx, az) and _covered(w, ax, az + dz) and _covered(w, ax + dx, az + dz):
				continue
			var a := j * vx + i
			idx.append_array(PackedInt32Array([a, a + 1, a + vx, a + 1, a + vx + 1, a + vx]))
	if idx.is_empty():
		return
	tri_count += idx.size() / 3
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHADER_CODE
	mat.shader = sh
	mat.set_shader_parameter("albedo", Vector3(albedo.r, albedo.g, albedo.b))
	mat.set_shader_parameter("planet_r", planet_r)
	var tf: String = r.get("texture", "")
	if tf != "" and FileAccess.file_exists(dir + tf):
		var img := Image.load_from_file(ProjectSettings.globalize_path(dir + tf))
		if img != null:
			img.convert(Image.FORMAT_L8)
			img.generate_mipmaps()
			var d8 := img.get_data()
			var sum := 0.0
			for k in range(0, d8.size(), 7):
				sum += d8[k]
			mat.set_shader_parameter("tex", ImageTexture.create_from_image(img))
			mat.set_shader_parameter("tex_mean", maxf(sum / (d8.size() / 7.0) / 255.0, 0.01))
			mat.set_shader_parameter("tex_on", 1.0)
			var tr: Array = r["tex_rect"]
			mat.set_shader_parameter("tex_rect", Vector4(tr[0], tr[1], tr[2], tr[3]))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.custom_aabb = AABB(Vector3(x0, -3000, z0), Vector3(cx * dx, 7000, cz * dz))
	mi.name = "ring_" + str(r["id"])
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
