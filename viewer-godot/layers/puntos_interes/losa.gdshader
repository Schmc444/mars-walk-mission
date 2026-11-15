shader_type spatial;
render_mode cull_disabled;
// Roca Bunsen Peak (recreacion aproximada): textura = recorte de refs/ref_panel_c.png proyectado desde arriba (UV = u, v de la losa).
uniform sampler2D tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tono = vec3(1.0);

// --- capa de detalle superficial (WATSON sol 1088, refs/detalle_cg2.png) encima del material: dos escalas mezcladas, con rotacion y
// desplazamiento distintos, en mapeo triplanar (sin estiramiento en los costados). Parametros en puntos.json -> roca -> detalle.
uniform sampler2D detalle : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float det_int = 0.0;                       // intensidad de la mezcla (0 = capa apagada)
uniform vec4 det_a = vec4(0.04, 0.35, 0.0, 0.0);   // escala (m por repeticion), rotacion (rad), desplazamiento (fraccion de la imagen) x, y
uniform vec4 det_b = vec4(0.12, 1.17, 0.37, 0.61);
uniform vec2 tri_base = vec2(0.0, 1.5);            // x: mezcla triplanar de la textura base en los costados (0..1); y: tamano del mosaico (m)
uniform vec3 n_losa = vec3(0.0, 1.0, 0.0);         // normal de la losa (para distinguir la cara superior de los costados)

varying vec3 lp;     // posicion local (relativa a la boca del futuro hueco: numeros pequenos y exactos)
varying vec3 ln;     // normal local

void vertex() {
	lp = VERTEX;
	ln = NORMAL;
}

vec2 rot(vec2 p, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}
vec2 espejo(vec2 t) { return 1.0 - abs(2.0 * fract(t * 0.5) - 1.0); }   // repeticion en espejo: sin costuras

vec3 tri_det(vec3 p, vec3 w, vec4 L) {
	vec2 a = espejo(rot(p.yz, L.y) / L.x + L.zw);
	vec2 b = espejo(rot(p.xz, L.y) / L.x + L.zw);
	vec2 c = espejo(rot(p.xy, L.y) / L.x + L.zw);
	return texture(detalle, a).rgb * w.x + texture(detalle, b).rgb * w.y + texture(detalle, c).rgb * w.z;
}

void fragment() {
	vec3 N = normalize(ln);
	vec3 w = pow(abs(N), vec3(4.0));
	w /= (w.x + w.y + w.z);
	vec3 base = texture(tex, UV).rgb;
	if (tri_base.x > 0.0) {
		// los costados usan la misma textura en triplanar (en vez de la proyeccion desde arriba, que se estira hacia abajo)
		float lado = smoothstep(0.55, 0.9, 1.0 - dot(N, n_losa)) * tri_base.x;
		vec3 tb = texture(tex, lp.yz / tri_base.y).rgb * w.x + texture(tex, lp.xz / tri_base.y).rgb * w.y + texture(tex, lp.xy / tri_base.y).rgb * w.z;
		base = mix(base, tb, lado);
	}
	vec3 col = base * tono;
	if (det_int > 0.0) {
		vec3 med = max(textureLod(detalle, vec2(0.5), 12.0).rgb, vec3(0.02));       // color medio del recorte (el ultimo nivel de mipmap)
		vec3 d = (tri_det(lp, w, det_a) + tri_det(lp, w, det_b)) * 0.5;
		col *= mix(vec3(1.0), d / med, det_int);                                     // multiplicacion suave: conserva color y aspecto
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
}
