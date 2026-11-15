extends Node3D
# Capa cartel_muestras: cartel de informacion estilo museo junto a cada muestra de muestras.json.
# Es independiente de puntos_interes: solo LEE puntos.json para saber donde esta cada muestra y NO toca el hueco.
# Para agregar otra muestra (25, 29, 30...) basta anadir una entrada a muestras.json (ver LEEME.md). Sin tocar codigo.

var world: WorldStreamer
var core: Node


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	var datos = JSON.parse_string(FileAccess.get_file_as_string("res://layers/cartel_muestras/muestras.json"))
	if datos == null or not datos is Array:
		push_error("cartel_muestras: muestras.json no es una lista JSON valida")
		return
	var puntos = JSON.parse_string(FileAccess.get_file_as_string("res://layers/puntos_interes/puntos.json"))
	for m in datos:
		var xz := Vector2.ZERO
		if m.has("lon") and m.has("lat"):
			xz = world.lonlat_to_world(m["lon"], m["lat"])
		elif m.has("punto") and puntos is Array:
			var hallado := false
			for p in puntos:
				if p.get("nombre", "") == m["punto"]:
					if p.has("x") and p.has("z"):
						xz = Vector2(p["x"], p["z"])
					else:
						xz = world.lonlat_to_world(p["lon"], p["lat"])
					hallado = true
			if not hallado:
				push_warning("cartel_muestras: no existe el punto '%s' en puntos.json" % m["punto"])
				continue
		else:
			push_warning("cartel_muestras: la entrada necesita 'punto' o 'lon'/'lat'")
			continue
		var n := Node3D.new()
		n.name = "cartel_" + str(m.get("punto", "muestra"))
		n.set_script(load("res://layers/cartel_muestras/cartel.gd"))
		add_child(n)
		n.setup(world, core, m, xz)
		print("cartel_muestras: ", m.get("titulo", "?"), " -> x=", snappedf(xz.x, 0.1), " z=", snappedf(xz.y, 0.1))
