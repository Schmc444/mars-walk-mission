shader_type spatial;
// Vistas de falso color de la capa Atmosfera: P calor, O radiacion, K oxigeno, M presion, N polvo.
// Cuadro pegado a la camara que cubre la pantalla y reemplaza la imagen por una paleta de falso color
// (azul = menos ... cian, verde, amarillo, rojo ... magenta = mas de ese parametro). Funciona con el renderer Mobile.
//   Calor: temperatura del aire del mapa en ese punto + el sol que recibe la superficie (segun su orientacion)
//          + el brillo de la escena (las sombras salen mas frias). El cielo de Marte sale frio.
//   Radiacion / oxigeno / presion / polvo: el valor del mapa en ese punto, con un poco del relieve para orientarse.
//   Cielo: radiacion alta (de ahi llegan los rayos cosmicos); oxigeno y presion bajos (bajan con la altura);
//          polvo medio. En la vista de polvo los remolinos se ven como columnas.
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled;

#ifdef USE_MULTIVIEW
uniform sampler2DArray depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2DArray screen_texture : hint_screen_texture, filter_linear;
#else
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
#endif

uniform sampler2D campo : filter_linear, repeat_disable;   // R polvo, G radiacion, B falta de O2 (0..1), A suelo (m)
uniform sampler2D campo2 : filter_linear, repeat_disable;  // R presion (Pa), G temperatura del aire (K)
uniform vec2 campo_origen;
uniform float campo_tam = 3200.0;
uniform int vista = 0;                                     // 0 calor, 1 radiacion, 2 oxigeno, 3 presion, 4 polvo
uniform vec3 sol_vec = vec3(0.5, 0.57, 0.6);               // direccion hacia el sol
uniform float dia = 1.0;                                   // 0 noche .. 1 sol alto
uniform float temp_aire = 215.0;                           // K, mediana del mapa (fuera del mapa se usa esta)
uniform vec2 escala_calor = vec2(200.0, 250.0);            // K del azul y del magenta
uniform vec2 escala = vec2(0.0, 1.0);                      // vistas 1-4: valor del azul y del magenta (lo pone layer.gd)
uniform float mediana = 0.4;                               // vistas 1-4: valor fuera del mapa
uniform float cielo_t = 0.85;                              // vistas 1-4: posicion del cielo en la paleta
uniform int n_remolinos = 0;
uniform vec4 remolinos[16];                                // x, z, radio, alto
uniform float calor_sol = 35.0;                            // K que gana una superficie de frente al sol alto
uniform float calor_brillo = 18.0;                        // K de mas/menos segun el brillo de la escena
uniform float sombreado = 0.55;                           // 0..1: cuanto relieve/imagen satelital se ve bajo el falso color
uniform float detalle = 0.12;                             // vistas 1-4: relieve visible (del brillo de la escena)

// Valor del mapa en uv para las vistas 1-4, "orientado": mas alto = mas de ese parametro.
float valor_vista(vec2 uv) {
	vec4 f = texture(campo, uv);
	if (vista == 1) return f.g;
	if (vista == 2) return 1.0 - f.b;                      // el mapa guarda la falta de O2
	if (vista == 3) return texture(campo2, uv).r;
	return f.r;
}

// Paleta de camara termica.
vec3 paleta(float t) {
	t = clamp(t, 0.0, 1.0);
	vec3 c0 = vec3(0.05, 0.10, 0.60);   // azul
	vec3 c1 = vec3(0.00, 0.75, 1.00);   // cian
	vec3 c2 = vec3(0.10, 0.95, 0.40);   // verde
	vec3 c3 = vec3(1.00, 0.95, 0.10);   // amarillo
	vec3 c4 = vec3(1.00, 0.35, 0.05);   // rojo anaranjado
	vec3 c5 = vec3(1.00, 0.10, 0.85);   // magenta
	float s = t * 5.0;
	if (s < 1.0) return mix(c0, c1, s);
	if (s < 2.0) return mix(c1, c2, s - 1.0);
	if (s < 3.0) return mix(c2, c3, s - 2.0);
	if (s < 4.0) return mix(c3, c4, s - 3.0);
	return mix(c4, c5, s - 4.0);
}

// La escena usa tonemapping ACES (del nucleo), que aclara y desatura. Para que la paleta se vea como se definio:
// sRGB -> lineal, y luego la inversa aproximada de la curva ACES (Narkowicz).
vec3 sin_tonemap(vec3 c) {
	vec3 y = clamp(pow(c, vec3(2.2)), 0.0, 0.95);
	return (-0.59 * y + 0.03 - sqrt(-1.0127 * y * y + 1.3702 * y + 0.0009)) / (2.0 * (2.43 * y - 2.51));
}

float dentro_campo(vec2 uv) {
	return smoothstep(0.0, 0.05, uv.x) * smoothstep(1.0, 0.95, uv.x) * smoothstep(0.0, 0.05, uv.y) * smoothstep(1.0, 0.95, uv.y);
}

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
#ifdef USE_MULTIVIEW
	float depth = texture(depth_texture, vec3(SCREEN_UV, float(VIEW_INDEX))).r;
	vec3 escena = texture(screen_texture, vec3(SCREEN_UV, float(VIEW_INDEX))).rgb;
#else
	float depth = texture(depth_texture, SCREEN_UV).r;
	vec3 escena = texture(screen_texture, SCREEN_UV).rgb;
#endif
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vp.xyz /= vp.w;
	vec3 wp = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;
	bool cielo = depth <= 1e-6;
	// brillo de la escena en escala perceptual (la textura de pantalla viene en lineal): ~0.5 en suelo iluminado
	float brillo = pow(max(dot(escena, vec3(0.299, 0.587, 0.114)), 0.0), 1.0 / 2.2);

	vec2 uv = (wp.xz - campo_origen) / campo_tam;
	float k = cielo ? 0.0 : dentro_campo(uv);
	float t;
	if (vista == 0) {
		if (cielo) {
			t = 0.02;                                            // cielo de Marte: frio
		} else {
			// normal suave del terreno a partir de las alturas del mapa (casillas de campo_tam / 160 m);
			// el detalle fino (rocas, sombras) lo da el brillo de la escena
			float du = 1.0 / 160.0;
			float celda = campo_tam / 160.0;
			float hx = texture(campo, uv + vec2(du, 0.0)).a - texture(campo, uv - vec2(du, 0.0)).a;
			float hz = texture(campo, uv + vec2(0.0, du)).a - texture(campo, uv - vec2(0.0, du)).a;
			vec3 n = normalize(mix(vec3(0.0, 1.0, 0.0), vec3(-hx / (2.0 * celda), 1.0, -hz / (2.0 * celda)), k));
			float aire = mix(temp_aire, texture(campo2, uv).g, k);
			float sup = aire + calor_sol * dia * max(dot(n, normalize(sol_vec)), 0.0)
				- 8.0 * (1.0 - dia)                             // de noche el suelo se enfria bajo el aire
				+ calor_brillo * (brillo - 0.45) * 2.0;
			t = (sup - escala_calor.x) / (escala_calor.y - escala_calor.x);
		}
	} else {
		if (cielo) {
			t = cielo_t;
		} else {
			float x = mix(mediana, valor_vista(uv), k);
			t = (x - escala.x) / (escala.y - escala.x) + detalle * (brillo - 0.45) * 2.0;
		}
		// polvo: remolinos como columnas (el rayo pasa cerca del eje, por debajo de su altura y antes del suelo)
		if (vista == 4) {
			vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
			vec3 rd = wp - cam;
			float dist = cielo ? 5000.0 : length(rd);
			rd = normalize(rd);
			vec2 dxz = rd.xz;
			float l2 = max(dot(dxz, dxz), 1e-6);
			for (int i = 0; i < n_remolinos; i++) {
				vec4 r = remolinos[i];
				float tc = clamp(dot(r.xy - cam.xz, dxz) / l2, 0.0, dist);
				float d = length(cam.xz + dxz * tc - r.xy) / r.z;
				float suelo = texture(campo, (r.xy - campo_origen) / campo_tam).a;
				float alto = cam.y + rd.y * tc - suelo;
				// borde suave hacia los lados y hacia arriba (se deshace en el ultimo 40 % de su altura)
				float w = exp(-d * d * 1.5) * smoothstep(r.w, r.w * 0.6, alto) * step(-5.0, alto);
				t = mix(t, 0.97, w);
			}
		}
	}
	vec3 col = paleta(t);
	if (!cielo) {
		// relieve: normal de la superficie a partir de la profundidad (alcanza las montanas lejanas) + brillo de la escena (imagen satelital y sombras)
		vec3 ng = normalize(cross(dFdx(wp), dFdy(wp)));
		if (ng.y < 0.0) ng = -ng;
		float luz = clamp(dot(ng, normalize(sol_vec)), 0.0, 1.0);
		float relieve = mix(0.55, 1.35, luz);
		float imagen = clamp(brillo / 0.5, 0.45, 1.5);
		col *= mix(vec3(1.0), vec3(relieve * imagen), sombreado);
	}
	ALBEDO = sin_tonemap(clamp(col, 0.0, 1.0));
	ALPHA = 1.0;
}
