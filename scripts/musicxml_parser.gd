class_name MusicXMLParser
extends RefCounted


var tempo := 50.0
var divisions := 4
var beats_per_measure := 4
var beat_type := 4
var beats: Array = []
var bars: Array = []


func parse(xml_path: String) -> void:
	var parser := XMLParser.new()
	if parser.open(xml_path) != OK:
		push_error("Cannot open MusicXML: " + xml_path)
		return
	var current_beat := 0.0
	var in_measure := false
	var measure_beat := 0.0
	var current_part := ""
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var tag := parser.get_node_name()
				match tag:
					"part":
						current_part = _attr(parser, "id")
						current_beat = 0.0
						measure_beat = 0.0
					"measure":
						in_measure = true
						measure_beat = 0.0
						var measure_num := _attr(parser, "number").to_int()
						if measure_num > 0:
							bars.append({"bar": measure_num, "time_sec": current_beat * 60.0 / tempo})
					"divisions":
						if parser.read() == OK and parser.get_node_type() == XMLParser.NODE_TEXT:
							divisions = parser.get_node_data().to_int()
					"beats":
						if parser.read() == OK and parser.get_node_type() == XMLParser.NODE_TEXT:
							beats_per_measure = parser.get_node_data().to_int()
					"beat-type":
						if parser.read() == OK and parser.get_node_type() == XMLParser.NODE_TEXT:
							beat_type = parser.get_node_data().to_int()
					"sound":
						var t := _attr(parser, "tempo")
						if t.length() > 0:
							tempo = t.to_float()
					"note":
						var note_info := _read_note(parser)
						if note_info.grace:
							pass
						elif not note_info.rest and note_info.duration > 0:
							var beat_seconds := current_beat + measure_beat
							beats.append({
								"time": beat_seconds,
								"duration_beats": float(note_info.duration) / float(divisions),
								"default_x": note_info.default_x,
								"part": current_part,
								"measure_beat": measure_beat,
							})
							if not note_info.chord:
								measure_beat += float(note_info.duration) / float(divisions)
					"forward":
						if parser.read() == OK and parser.get_node_type() == XMLParser.NODE_TEXT:
							var dur: int = parser.get_node_data().to_int()
							measure_beat += float(dur) / float(divisions)
			XMLParser.NODE_ELEMENT_END:
				if parser.get_node_name() == "measure":
					if in_measure:
						current_beat += measure_beat
						in_measure = false
	beats.sort_custom(func(a, b): return a.time < b.time)


func get_total_time() -> float:
	if beats.is_empty():
		return 0.0
	var last: Dictionary = beats.back()
	var total_beats: float = last.time + last.duration_beats
	return total_beats * (60.0 / tempo)


func get_tempo() -> float:
	return tempo


class NoteInfo:
	var rest := false
	var chord := false
	var grace := false
	var duration := 0
	var default_x := 0.0


func _read_note(parser: XMLParser) -> NoteInfo:
	var info := NoteInfo.new()
	var dx := _attr(parser, "default-x")
	if dx.length() > 0:
		info.default_x = dx.to_float()
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT_END and parser.get_node_name() == "note":
			return info
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			match parser.get_node_name():
				"rest":
					info.rest = true
				"chord":
					info.chord = true
				"grace":
					info.grace = true
				"duration":
					if parser.read() == OK and parser.get_node_type() == XMLParser.NODE_TEXT:
						info.duration = parser.get_node_data().to_int()
	return info


func _attr(p: XMLParser, n: String) -> String:
	for i in range(p.get_attribute_count()):
		if p.get_attribute_name(i) == n:
			return p.get_attribute_value(i)
	return ""
