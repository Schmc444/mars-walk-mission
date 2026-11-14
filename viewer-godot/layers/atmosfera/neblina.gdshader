shader_type spatial;
// Neblina de la capa Atmosfera: un cuadro pegado a la camara que cubre la pantalla y recorre el rayo de cada pixel
// (hasta el suelo o hasta `dist_max`) leyendo el mapa de valores alrededor del jugador. Asi las zonas se ven de lejos
// y, al entrar en una, la neblina rodea al jugador. Funciona con el renderer Mobile (lee la textura de profundidad).
// Ademas, donde el rayo toca el suelo se pinta una capa baja pegada al terreno con el valor de ese punto
// (tinte_suelo), para que las zonas se lean sobre el terreno cercano y no solo en el horizonte.
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled;

#ifdef USE_MULTIVIEW
uniform sampler2DArray depth_texture : hint_depth_texture, filter_nearest;
#else
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
#endif

uniform sampler2D campo : filter_linear, repeat_disable;   // R polvo, G radiacion, B falta de O2 (0..1), A suelo (m)
uniform sampler2D campo2 : filter_linear, repeat_disable;  // R presion (Pa), G temperatura (K), valores reales
uniform vec2 rango_local = vec2(800.0, 750.0);             // presion/temperatura: valor del tono claro y del oscuro
uniform vec2 campo_origen;                                 // esquina oeste-norte (x, z) en metros
uniform float campo_tam = 3200.0;                          // lado en metros
uniform int modo = 0;                                      // 0 polvo, 1 radiacion, 2 oxigeno, 3 presion, 4 temperatura
uniform vec3 color_claro : source_color;
uniform vec3 color_medio : source_color;
uniform vec3 color_oscuro : source_color;
uniform float densidad = 0.006;
uniform float piso = 0.015;                                // densidad minima (fuera de zonas); baja = cielo mas limpio
uniform float alto_capa = 18.0;                            // m: grosor de la capa sobre el suelo
uniform float dist_max = 1200.0;
uniform float opacidad_max = 0.8;                          // tope sobre el terreno
uniform float opacidad_cielo = 0.45;                       // tope en el cielo (deja ver montanias y horizonte)
uniform float tinte_suelo = 0.5;                           // opacidad maxima de la capa pegada al suelo
uniform vec2 rango_suelo = vec2(0.3, 0.9);                 // p50 y p95 del mapa actual (lo pone layer.gd): resalta las zonas altas
uniform int n_remolinos = 0;
uniform vec4 remolinos[16];                                // x, z, radio, alto

const int PASOS = 24;
const int MAX_REM_RAYO = 4;                                // remolinos que se evaluan por pixel (los que cruza el rayo)

// Intensidad 0 (claro) .. 1 (oscuro) en uv; f = texel del primer mapa (ya leido, trae la altura del suelo en A).
float valor_campo(vec4 f, vec2 uv) {
	if (modo < 3) {
		return modo == 0 ? f.r : (modo == 1 ? f.g : f.b);
	}
	vec2 g = texture(campo2, uv).rg;
	float x = modo == 3 ? g.r : g.g;
	return clamp((rango_local.x - x) / (rango_local.x - rango_local.y), 0.0, 1.0);
}

vec3 rampa(float t) {
	return t < 0.5 ? mix(color_claro, color_medio, t * 2.0) : mix(color_medio, color_oscuro, t * 2.0 - 1.0);
}

float borde_campo(vec2 uv) {
	return smoothstep(0.0, 0.05, uv.x) * smoothstep(1.0, 0.95, uv.x) * smoothstep(0.0, 0.05, uv.y) * smoothstep(1.0, 0.95, uv.y);
}

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
#ifdef USE_MULTIVIEW
	float depth = texture(depth_texture, vec3(SCREEN_UV, float(VIEW_INDEX))).r;
#else
	float depth = texture(depth_texture, SCREEN_UV).r;
#endif
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vp.xyz /= vp.w;
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 wp = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;
	vec3 rd = wp - cam;
	float dist = length(rd);
	rd /= max(dist, 1e-4);
	bool cielo = depth <= 1e-6;
	if (cielo) {
		dist = dist_max;
	}
	dist = min(dist, dist_max);

	// Remolinos que este rayo cruza de verdad (en planta), para no recorrer los 16 en cada paso.
	int sel[MAX_REM_RAYO];
	int n_sel = 0;
	if (modo == 0) {
		vec2 dxz = rd.xz;
		float l2 = max(dot(dxz, dxz), 1e-6);
		for (int k = 0; k < n_remolinos; k++) {
			if (n_sel >= MAX_REM_RAYO) {
				break;
			}
			vec4 r = remolinos[k];
			vec2 oc = r.xy - cam.xz;
			float tc = clamp(dot(oc, dxz) / l2, 0.0, dist);    // punto del rayo mas cercano al eje del remolino
			if (length(cam.xz + dxz * tc - r.xy) < 2.5 * r.z) {
				sel[n_sel] = k;
				n_sel++;
			}
		}
	}

	vec3 acum = vec3(0.0);
	float trans = 1.0;
	float t0 = 0.0;
	for (int i = 0; i < PASOS; i++) {
		float u = float(i + 1) / float(PASOS);
		float t1 = dist * u * u;                       // pasos cortos cerca, largos lejos
		float tm = 0.5 * (t0 + t1);
		vec3 p = cam + rd * tm;
		vec2 uv = (p.xz - campo_origen) / campo_tam;
		float borde = borde_campo(uv);
		vec4 f = texture(campo, uv);
		float v = valor_campo(f, uv);
		float sobre = p.y - f.a;
		float perfil = exp(-max(sobre, 0.0) / alto_capa);
		for (int s = 0; s < n_sel; s++) {
			vec4 r = remolinos[sel[s]];
			float d = length(p.xz - r.xy) / r.z;
			float columna = sobre < r.w ? 1.0 : exp(-(sobre - r.w) / 40.0);
			float c = exp(-d * d) * columna;
			v = max(v, c);
			perfil = max(perfil, c);
		}
		float dens = densidad * (piso + 5.0 * v * v * v) * perfil * borde;
		float a = 1.0 - exp(-dens * (t1 - t0));
		acum += trans * a * rampa(v);
		trans *= 1.0 - a;
		t0 = t1;
		// cortes: ya casi opaco, o el rayo va subiendo y salio de la capa (sin remolinos en este rayo)
		if (trans < 0.02 || (n_sel == 0 && rd.y > 0.0 && sobre > 6.0 * alto_capa)) {
			break;
		}
	}

	// Capa baja pegada al terreno en el punto donde el rayo toca el suelo.
	if (!cielo && dist < dist_max) {
		vec2 uv = (wp.xz - campo_origen) / campo_tam;
		float vs = valor_campo(texture(campo, uv), uv);
		float a = tinte_suelo * smoothstep(rango_suelo.x, rango_suelo.y, vs) * borde_campo(uv);
		a *= smoothstep(dist_max, dist_max * 0.6, dist);   // se apaga suave hacia el limite del mapa
		acum += trans * a * rampa(vs);
		trans *= 1.0 - a;
	}

	float alfa = 1.0 - trans;
	ALBEDO = alfa > 1e-4 ? acum / alfa : vec3(0.0);
	ALPHA = min(alfa, cielo ? opacidad_cielo : opacidad_max);
}
