shader_type spatial;
// Interior del hueco (tubo) y del parche (cilindro corto) insertados en el terreno.
//
// PRECISION: todo se calcula en el espacio LOCAL de la malla (numeros pequenos y exactos). El hueco esta a ~7 km del origen del
// visor, donde las coordenadas del mundo en float de 32 bits solo distinguen pasos de ~0.5 mm (el radio del hueco es de 6.5 mm):
// usarlas aqui producia escalones y franjas planas. El eje del cilindro es +Y local (hacia dentro del suelo).
//
// Se recorta todo lo que queda por ENCIMA del plano del suelo (el terreno es una superficie sin grosor) y, opcionalmente, la
// mitad del lado del corte. Ambos planos llegan ya expresados en el espacio local (plano_n_loc/plano_c y corte_n_loc/corte_c).
//
// PAREDES DEL HUECO (usa_pared = true): textura mapeada en cilindro alrededor del eje, a escala fisica real, con repeticion en
// espejo (sin costura). APROXIMACION: no existe ninguna imagen del interior real; se usa la superficie de la roca antes de perforar
// (mosaico WATSON del sol 1088), mas oscura y desaturada, con un degradado que oscurece hacia el fondo y un relieve suave
// derivado de la propia luminosidad. El fondo (tapa) del hueco NO se texturiza: sigue con el color plano casi negro.
render_mode cull_disabled;

uniform vec3 plano_n_loc = vec3(0.0, 1.0, 0.0);
uniform float plano_c = 0.0;                    // dot(v, plano_n_loc) + plano_c > clip_eps  =>  por encima del suelo
uniform float clip_eps = 0.0002;                // hasta donde sube la pared sobre el plano (el hueco la sube hasta el collar)
uniform float s_c = 0.0;                        // profundidad (sobre el eje) del centro del cilindro
uniform float prof_total = 0.058;
uniform vec3 color_arriba : source_color = vec3(0.30, 0.20, 0.14);
uniform vec3 color_fondo : source_color = vec3(0.05, 0.035, 0.03);
uniform bool corte_on = false;
uniform vec3 corte_n_loc = vec3(0.0, 0.0, 1.0);
uniform float corte_c = 0.0;                    // dot(v, corte_n_loc) + corte_c > 0  =>  lado que se quita

// --- paredes texturizadas ---
uniform bool usa_pared = false;
uniform sampler2D tex_pared : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 ref_loc = vec3(1.0, 0.0, 0.0);     // vector unitario perpendicular al eje (local): origen del angulo
uniform float radio_pared = 0.0065;
uniform float tex_w = 0.0204;                   // ancho fisico de la textura (m)
uniform float tex_h = 0.0137;                   // alto fisico de la textura (m)
uniform float tex_px = 122.0e-6;                // tamano fisico de un pixel de la textura (m)
uniform float n_u = 2.0;                        // anchos de textura que caben en la circunferencia (PAR => sin costura)
uniform float brillo = 0.55;
uniform float saturacion = 0.55;
uniform float degradado = 0.95;                 // 0 = sin oscurecer con la profundidad, 1 = negro total al fondo
uniform float relieve = 1.0;                    // 0 = sin relieve

varying vec3 lp;

void vertex() {
	lp = VERTEX;
}

// repeticion en espejo: 0..1..0..1 (continua)
float esp(float x) {
	return 1.0 - abs(fract(x * 0.5) * 2.0 - 1.0);
}
// signo de la derivada de esp()
float esp_d(float x) {
	return fract(x * 0.5) < 0.5 ? 1.0 : -1.0;
}

void fragment() {
	if (dot(lp, plano_n_loc) + plano_c > clip_eps) {
		discard;
	}
	if (corte_on && dot(lp, corte_n_loc) + corte_c > 0.0) {
		discard;
	}
	float s = lp.y + s_c;
	float d01 = clamp(s / prof_total, 0.0, 1.0);
	vec3 radial = vec3(lp.x, 0.0, lp.z);
	float rl = length(radial);
	bool es_pared = usa_pared && rl > radio_pared * 0.97;     // la tapa del fondo (rl < radio) queda como estaba
	if (!es_pared) {
		ALBEDO = mix(color_arriba, color_fondo, smoothstep(0.0, 1.0, d01));
		ROUGHNESS = 1.0;
		AO = 1.0 - 0.85 * d01;
		AO_LIGHT_AFFECT = 0.8;
	} else {
		vec3 rd = radial / max(rl, 1e-7);                      // direccion radial (hacia la pared)
		vec3 eje_l = vec3(0.0, 1.0, 0.0);
		vec3 rv = cross(eje_l, ref_loc);
		float ang = atan(dot(rd, rv), dot(rd, ref_loc));       // -pi..pi
		float u = ang / TAU * n_u;
		float v = s / tex_h;
		vec2 uv = vec2(esp(u), esp(v));
		float ps = length(fwidth(lp));                          // huella de un pixel en pantalla (m)
		float lod = max(log2(max(ps, 1e-9) / tex_px), 0.0);
		vec3 c = textureLod(tex_pared, uv, lod).rgb;
		// relieve: gradiente de luminosidad de la propia textura -> normal inclinada sobre la pared
		vec2 px = vec2(1.0) / vec2(textureSize(tex_pared, 0));
		float lu = dot(textureLod(tex_pared, uv + vec2(px.x, 0.0), lod).rgb - textureLod(tex_pared, uv - vec2(px.x, 0.0), lod).rgb, vec3(0.333));
		float lv = dot(textureLod(tex_pared, uv + vec2(0.0, px.y), lod).rgb - textureLod(tex_pared, uv - vec2(0.0, px.y), lod).rgb, vec3(0.333));
		vec3 T = normalize(cross(eje_l, rd));                  // direccion en que crece el angulo
		vec3 B = eje_l;                                        // direccion en que crece la profundidad
		vec3 N = -rd;                                          // normal hacia el interior del hueco
		vec3 n = normalize(N - relieve * 2.0 * (lu * esp_d(u) * T + lv * esp_d(v) * B));
		NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(n, 0.0)).xyz);
		// mas oscura y desaturada que la superficie, y cada vez mas oscura hacia el fondo
		float lum = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(vec3(lum), c, saturacion) * brillo;
		float grad = 1.0 - degradado * smoothstep(0.0, 1.0, d01);
		ALBEDO = c * grad;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;                                        // mate
		AO = 1.0 - 0.85 * d01;
		AO_LIGHT_AFFECT = 0.8;
	}
}
