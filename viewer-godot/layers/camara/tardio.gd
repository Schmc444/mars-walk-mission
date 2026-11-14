extends Node
# Corre despues de todo _process (incluido el del visor, que reescribe cam.rotation) para colocar la camara.
var capa: Node

func _process(_d: float) -> void:
	capa._late()
