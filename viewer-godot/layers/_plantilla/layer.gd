extends Node3D
# PLANTILLA de capa. Copia esta carpeta a layers/<tu_capa>/ (sin "_" al inicio) y edita SOLO tus archivos.
# El visor carga automaticamente layers/*/layer.gd y llama a setup() una vez que el mundo esta listo.
#
#   world : el mundo (world.gd)
#     world.height_at(x, z)                  altura del suelo en metros (y = arriba)
#     world.slope_deg(x, z)                  pendiente en grados
#     world.lonlat_to_world(lon, lat)        -> Vector2(x, z) en metros
#     world.world_to_lonlat(x, z)            -> Vector2(lon, lat)
#     world.route_length(), route_pos(s), route_sol_at(s), route_s_of_sol(sol), route_nearest_s(Vector2)
#   core  : el visor (main.gd)
#     core.origin      nodo del jugador (core.origin.global_position = donde estas)
#     core.cam         camara; core.left / core.right = controles de la mano
#     core.ride_s      metros recorridos por la ruta; core.riding = true si vas en el rover
#     core.sun_dir_xz  direccion horizontal de la luz del sol (Vector2)
#     core.hazard_on   capa de peligro encendida
#
# Ejes: x = este, z = sur, y = arriba. Todo en metros.

var world: WorldStreamer
var core: Node
var marcador: MeshInstance3D


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	# Ejemplo: una esfera roja 2 m a la derecha del punto de inicio de la ruta.
	marcador = MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.5
	s.height = 1.0
	marcador.mesh = s
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1, 0.1, 0.1)
	marcador.material_override = m
	add_child(marcador)
	marcador.position = Vector3(2, world.height_at(2, 0) + 0.5, 0)


func _process(_delta: float) -> void:
	pass
