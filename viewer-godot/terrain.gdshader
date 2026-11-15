shader_type spatial;
uniform sampler2D ortho : filter_linear_mipmap_anisotropic;
uniform bool hazard = false;
uniform float hazard_deg = 15.0;
varying float slope;
varying vec2 wpos;
uniform vec3 far_albedo = vec3(0.2, 0.14, 0.1);
uniform float patch_half = 50.0;
uniform bool stats = false;
uniform float o_mean = 0.5;
uniform float o_std = 0.15;
uniform float ring_gain = 1.0;
uniform vec2 shadow_dir = vec2(-0.64, -0.76); // horizontal direction the sunlight travels (x, z)
varying float vdist;
// --- capa puntos_interes: recortes del terreno bajo el hueco de la perforacion y el parche (apagados por defecto) ---
uniform vec4 rec_a = vec4(0.0);     // hueco: xz del centro (x,y) y activo (z>0.5)
uniform vec3 rec_a_m = vec3(0.0);   // forma cuadratica (sxx, sxy, syy)/R^2: dentro si w^T S w < 1
uniform vec4 rec_b = vec4(0.0);     // parche abrasionado (igual)
uniform vec3 rec_b_m = vec3(0.0);
uniform vec4 rec_c = vec4(0.0);     // corte: xz del centro (x,y) y normal xz (z,w)
uniform float rec_c_r = 0.0;        // radio del semidisco del corte (0 = apagado)
varying vec2 hxa;                   // posicion xz relativa a cada recorte, calculada SIN restar numeros grandes (precision)
varying vec2 hxb;
varying vec2 hxc;
uniform vec2 tile_origin = vec2(0.0);   // world xz of the mesh origin (tiled world); wpos stays in world metres
uniform float planet_r = 0.0;           // >0: drop the far ground below the horizon like the ring meshes
void vertex() {
  // (traslacion del modelo - centro del recorte) es una resta exacta de dos floats cercanos; luego se suma el vertice local
  vec2 m3 = MODEL_MATRIX[3].xz;
  hxa = VERTEX.xz + (m3 - rec_a.xy);
  hxb = VERTEX.xz + (m3 - rec_b.xy);
  hxc = VERTEX.xz + (m3 - rec_c.xy);
  slope = degrees(acos(clamp(NORMAL.y, 0.0, 1.0)));
  wpos = VERTEX.xz + tile_origin;
  if (planet_r > 0.0) {
    vec2 rel = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz - CAMERA_POSITION_WORLD.xz;
    VERTEX.y -= dot(rel, rel) / (2.0 * planet_r);
  }
}
float h21(vec2 p){ vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vn(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
  return mix(mix(h21(i),h21(i+vec2(1,0)),f.x), mix(h21(i+vec2(0,1)),h21(i+vec2(1,1)),f.x), f.y); }
// One pebble layer: a rotated, domain-warped jittered grid with at most one pebble per cell.
// Cell presence follows a clustered density field, centres jitter across the whole cell, each
// pebble is an ellipse of random size/orientation, so no lattice survives. Returns pebble height
// (0..1); grad = world-space height gradient (bump), ao = contact darkening just outside the rim.
float peb(vec2 p, float cell, float ang, float dens, out vec2 grad, out float tone, out float ao) {
  mat2 R = mat2(vec2(cos(ang), sin(ang)), vec2(-sin(ang), cos(ang)));
  vec2 q = (R * p) / cell; vec2 i = floor(q); vec2 f = fract(q);
  grad = vec2(0.0); ao = 1.0;
  tone = h21(i + 5.5);
  if (h21(i + 1.9) > dens) return 0.0;
  vec2 c = vec2(h21(i + 7.1), h21(i + 3.3)) * 0.7 + 0.15;
  float room = min(min(c.x, 1.0 - c.x), min(c.y, 1.0 - c.y));
  float s = h21(i + 9.7);
  float rad = min(mix(0.09, 0.42, s * s), room);
  float a = h21(i + 4.4) * 6.2832;
  vec2 ax = vec2(cos(a), sin(a));
  float el = mix(0.55, 1.0, h21(i + 2.6));
  vec2 dv = f - c;
  vec2 v = vec2(dot(dv, ax), dot(dv, vec2(-ax.y, ax.x)) / el) / rad;
  float u2 = dot(v, v);
  float hs = mix(0.25, 0.6, h21(i + 8.2)); // height/width: flat slabs to rounded pebbles
  // short cast shadow on the down-sun side (length ~ height / tan(sun elevation))
  vec2 ds = dv - (R * shadow_dir) * rad * hs * 1.4;
  vec2 vs = vec2(dot(ds, ax), dot(ds, vec2(-ax.y, ax.x)) / el) / rad;
  if (u2 >= 1.0) { ao = mix(0.62, 1.0, smoothstep(0.55, 1.1, dot(vs, vs))); return 0.0; }
  // dh/df of h = 1-u2, then back through the ellipse frame and the layer rotation (cell cancels)
  vec2 gl = -2.0 * (v.x * ax + (v.y / el) * vec2(-ax.y, ax.x)) / rad;
  grad = (transpose(R) * gl) * hs * rad;
  return 1.0 - u2;
}
void fragment() {
  if (rec_a.z > 0.5) { vec2 w = hxa; if (dot(w, vec2(rec_a_m.x * w.x + rec_a_m.y * w.y, rec_a_m.y * w.x + rec_a_m.z * w.y)) < 1.0) discard; }
  if (rec_b.z > 0.5) { vec2 w = hxb; if (dot(w, vec2(rec_b_m.x * w.x + rec_b_m.y * w.y, rec_b_m.y * w.x + rec_b_m.z * w.y)) < 1.0) discard; }
  if (rec_c_r > 0.0) { vec2 w = hxc; if (length(w) < rec_c_r && dot(w, rec_c.zw) > 0.0) discard; }
  float g = texture(ortho, UV).r;
  float d = vn(wpos*6.0)*0.5 + vn(wpos*23.0)*0.3 + vn(wpos*91.0)*0.2;
  float c = clamp((g - 0.227) / 0.313, 0.0, 1.0);
  vec3 dark = vec3(0.07, 0.042, 0.027);
  vec3 bright = vec3(0.3, 0.16, 0.08);
  if (stats) {
    c = clamp(0.5 + (g - o_mean) / (3.5 * o_std), 0.0, 1.0);
    dark = far_albedo * ring_gain * 0.6;
    bright = far_albedo * ring_gain * 1.3;
  }
  float near = 1.0 - smoothstep(25.0, 70.0, length(VERTEX));
  d = mix(vn(wpos*6.0)*0.5 + vn(wpos*23.0)*0.3 + 0.1, d, near);
  vec3 base = mix(dark, bright, c) * (0.85 + 0.3 * d);
  // metre-scale tint: greyer basaltic sand vs redder dust, plus a faint wind streak direction
  float hv = vn(wpos * vec2(0.22, 0.5) + 3.1) * 0.6 + vn(wpos * 1.4 + 9.0) * 0.4;
  base *= mix(vec3(0.9, 0.93, 1.0), vec3(1.07, 1.0, 0.93), smoothstep(0.25, 0.75, hv));
  float edge = max(abs(wpos.x), abs(wpos.y));
  base = mix(base, far_albedo * (stats ? ring_gain : 1.0) * (0.8 + 0.4 * d), smoothstep(patch_half - 20.0, patch_half - 1.0, edge));
  if (hazard) {
    float t = smoothstep(hazard_deg*0.6, hazard_deg*1.3, slope);
    base = mix(base, vec3(0.9,0.1,0.1), t*0.65);
  }
  // Pebbles: three rotated, warped layers (granules ~5 mm, pebbles ~1.5 cm, small cobbles ~4 cm),
  // clustered by a density field that also follows the ortho (darker ground = more clasts).
  // Each layer fades by its on-screen size (fwidth), so nothing shimmers in the headset.
  float fw = length(fwidth(wpos));
  vec2 wp = wpos + (vec2(vn(wpos * 1.3), vn(wpos * 1.3 + 17.0)) - 0.5) * 0.12;
  float cl = vn(wpos * 0.35 + 40.0) * 0.55 + vn(wpos * 1.6) * 0.3 + (1.0 - c) * 0.3;
  float D = smoothstep(0.35, 0.8, cl);
  vec3 L = vec3(0.016, 0.042, 0.1);   // cell sizes (m)
  vec3 W = vec3(1.0) - smoothstep(L * 0.3, L * 0.9, vec3(fw));
  vec2 gs = vec2(0.0); float hsum = 0.0; float aot = 1.0; float pc = 0.0; float pw = 0.0;
  vec2 gg; float tn; float oc; float h;
  h = peb(wp, L.x, 0.41, mix(0.15, 0.95, D), gg, tn, oc) * W.x;
  gs += gg * W.x; aot *= mix(1.0, oc, W.x); pc += h * mix(0.5, 1.3, tn); pw += h;
  h = peb(wp + 11.3, L.y, 1.93, mix(0.06, 0.7, D), gg, tn, oc) * W.y;
  gs += gg * W.y; aot *= mix(1.0, oc, W.y); pc += h * mix(0.45, 1.35, tn); pw += h;
  h = peb(wp - 5.7, L.z, 4.12, mix(0.01, 0.4, D * D), gg, tn, oc) * W.z;
  gs += gg * W.z; aot *= mix(1.0, oc, W.z); pc += h * mix(0.45, 1.3, tn); pw += h;
  NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(-gs.x, 0.0, -gs.y, 0.0)).xyz);
  // pebble albedo: dark grey basalt to dust-coated tan; sharp-ish so the clast reads as a stone
  float on = smoothstep(0.0, 0.15, pw);
  float k = pw > 0.0 ? pc / pw : 1.0;
  vec3 stone = mix(vec3(0.075, 0.066, 0.06), vec3(0.3, 0.19, 0.12), clamp(k - 0.45, 0.0, 1.0));
  base = mix(base, mix(stone, base, 0.25), on * 0.85);
  base *= aot;
  // once a layer is sub-pixel, keep its average darkening so gravelly patches still read
  base *= 1.0 - 0.1 * D * ((1.0 - W.x) + (1.0 - W.y)) * 0.5;
  // fine sand grain right at the feet
  base *= 1.0 + (h21(floor(wpos * 400.0)) - 0.5) * 0.12 * (1.0 - smoothstep(0.0015, 0.004, fw));
  ALBEDO = base;
  ROUGHNESS = 1.0;
}
