shader_type spatial;
// Cara del corte: plano vertical que pasa por el eje del hueco. Color plano; se recorta lo que queda sobre el suelo
// y el canal del hueco, para ver la mitad del tubo que queda detras.
// PRECISION: todo relativo al hueco (q = q0 + B * vertice), sin coordenadas del mundo (ver tubo.gdshader).
render_mode cull_disabled;

uniform vec3 q0 = vec3(0.0);                    // posicion del cuadrado relativa al hueco
uniform vec3 bx = vec3(1.0, 0.0, 0.0);          // columnas de la base del cuadrado
uniform vec3 by = vec3(0.0, 1.0, 0.0);
uniform vec3 bz = vec3(0.0, 0.0, 1.0);
uniform vec3 plano_n = vec3(0.0, 1.0, 0.0);     // normal del suelo; el suelo pasa por el hueco (origen)
uniform vec3 eje = vec3(0.0, -1.0, 0.0);
uniform float radio = 0.0065;
uniform float prof_total = 0.058;
uniform vec3 color : source_color = vec3(0.62, 0.40, 0.28);

varying vec3 qr;

void vertex() {
	qr = q0 + bx * VERTEX.x + by * VERTEX.y + bz * VERTEX.z;
}

void fragment() {
	if (dot(qr, plano_n) > 0.0002) {
		discard;
	}
	float s = dot(qr, eje);
	float d2 = dot(qr, qr) - s * s;
	if (d2 < radio * radio && s < prof_total) {
		discard;
	}
	ALBEDO = color;
	ROUGHNESS = 1.0;
}
