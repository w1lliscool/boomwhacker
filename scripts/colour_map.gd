class_name ColourMap
extends RefCounted


var colours: Dictionary = {}


func load_from_file(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts := line.split(" ", false)
		if parts.size() >= 2:
			var note := parts[0]
			var hex := parts[1]
			if not hex.begins_with("#"):
				hex = "#" + hex
			colours[note] = Color.html(hex)
	file.close()


func get_colour(note_name: String) -> Color:
	if colours.has(note_name):
		return colours[note_name]
	return Color.WHITE
