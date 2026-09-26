extends Control

const MusicXMLParserClass = preload("res://scripts/musicxml_parser.gd")
const ColourMapClass = preload("res://scripts/colour_map.gd")
const SONGS_DIR := "res://songs"

var song_folder := ""
var svg_path := ""
var xml_path := ""
var audio_path := ""
var cover_path := ""
var colours_path := ""
var sheet_png_path := ""
var last_trim_data: Dictionary = {}
var note_positions: Array = []
var scroll_map: Array = []
var tile_paths: Array = []
var tile_widths_svg: Array = []
var prepare_thread: Thread
var prepare_exit_code := -1
var active_render_scene: Node = null
var python_log: Array[String] = []
var cached_xml_data: Dictionary = {}


func _python_exe() -> String:
	var from_env := OS.get_environment("BOOMWHACKER_PYTHON")
	if not from_env.is_empty():
		return from_env
	return "python"


func _script_path(script_name: String) -> String:
	return ProjectSettings.globalize_path("res://scripts").path_join(script_name)


func _asset_path(name: String) -> String:
	if name.is_empty():
		return ""
	return song_folder.path_join(name.get_file())


func _ready() -> void:
	%ExportBtn.pressed.connect(_on_export)
	%ExportBtn.disabled = true
	%PreviewBtn.pressed.connect(_on_preview)
	%PreviewBtn.disabled = true
	%CancelBtn.pressed.connect(_on_cancel)
	%CancelBtn.disabled = true
	_populate_song_list()


# Every folder under songs/ that holds a MusicXML becomes a button, labelled with
# the title from that MusicXML.
func _populate_song_list() -> void:
	var list: VBoxContainer = %SongListBox
	for child in list.get_children():
		child.queue_free()
	var songs_path := ProjectSettings.globalize_path(SONGS_DIR)
	var dir := DirAccess.open(songs_path)
	if dir == null:
		%StatusLabel.text = "No songs folder at " + SONGS_DIR
		return
	var folders: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with("."):
			folders.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	folders.sort()
	if folders.is_empty():
		%StatusLabel.text = "No songs in " + SONGS_DIR
		return
	for folder_name in folders:
		var folder := songs_path.path_join(folder_name)
		var xml := _find_song_xml(folder)
		if xml.is_empty():
			continue
		var btn := Button.new()
		btn.text = _song_title(xml)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.tooltip_text = folder
		btn.pressed.connect(_on_dir_selected.bind(folder))
		list.add_child(btn)


func _find_song_xml(folder: String) -> String:
	var dir := DirAccess.open(folder)
	if dir == null:
		return ""
	var found := ""
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and not entry.begins_with("."):
			var ext := entry.get_extension().to_lower()
			if ext == "musicxml" or ext == "xml":
				found = entry
				break
		entry = dir.get_next()
	dir.list_dir_end()
	return folder.path_join(found) if not found.is_empty() else ""


# Prefers the title stored in the score, then the score's filename.
func _song_title(xml_path: String) -> String:
	var f := FileAccess.open(xml_path, FileAccess.READ)
	if f != null:
		var text := f.get_as_text()
		f.close()
		var re := RegEx.new()
		re.compile("<(?:work|movement)-title>([^<]+)</")
		var hit := re.search(text)
		if hit != null:
			var title := hit.get_string(1).strip_edges()
			if not title.is_empty():
				return title
	return _prettify(xml_path.get_file().get_basename())


func _prettify(raw: String) -> String:
	return raw.replace("_", " ").replace("-", " ").capitalize()


func _on_dir_selected(dir: String) -> void:
	song_folder = dir
	cached_xml_data = {}
	python_log = []
	_scan_folder()
	%SongLabel.text = song_folder.get_file()
	%SongName.text = song_folder.get_file().replace("_", " ").replace("-", " ").capitalize()
	%ExportBtn.disabled = true
	%PreviewBtn.disabled = true
	%StatusLabel.text = "Preparing..."
	%Progress.value = 0


func _scan_folder() -> void:
	svg_path = ""
	xml_path = ""
	audio_path = ""
	cover_path = ""
	colours_path = ""
	var dir := DirAccess.open(song_folder)
	if dir == null:
		%StatusLabel.text = "Cannot open " + song_folder
		return
	# Group by type instead of letting the loop overwrite as it goes. DirAccess
	# order is filesystem dependent, so "last one wins" silently picked a
	# different file depending on what was written most recently.
	var svgs: Array[String] = []
	var xmls: Array[String] = []
	var audios: Array[String] = []
	var covers: Array[String] = []
	var colour_maps: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not fname.begins_with("."):
			var lower := fname.to_lower()
			match fname.get_extension().to_lower():
				"svg":
					svgs.append(fname)
				"musicxml", "xml":
					xmls.append(fname)
				"mp3", "wav", "ogg":
					audios.append(fname)
				"png", "jpg", "jpeg":
					if lower.begins_with("cover"):
						covers.append(fname)
				"txt":
					if lower.begins_with("colour") or lower.begins_with("color"):
						colour_maps.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	# prepare_svg.py writes trimmed.svg as an intermediate, so feeding that back
	# in as the source sheet would work but only by accident.
	svg_path = _pick_song_file(svgs, song_folder.get_file())
	xml_path = _pick_song_file(xmls, song_folder.get_file())
	audio_path = _pick_song_file(audios, song_folder.get_file())
	if not covers.is_empty():
		covers.sort()
		cover_path = song_folder.path_join(covers[0])
	if not colour_maps.is_empty():
		colour_maps.sort()
		colours_path = song_folder.path_join(colour_maps[0])
	if svg_path.is_empty():
		%StatusLabel.text = "No SVG found"
		return
	if xml_path.is_empty():
		%StatusLabel.text = "No MusicXML found"
		return
	if audio_path.is_empty():
		audio_path = song_folder.path_join("generated_audio.wav")
		_generate_audio_from_musicxml(xml_path, audio_path)
	_prepare_assets_async()


# Prefers a file named after the song folder, then the shortest name, so the same
# folder always resolves to the same inputs.
func _pick_song_file(candidates: Array[String], folder_name: String) -> String:
	var usable: Array[String] = []
	for c in candidates:
		var base := c.get_basename().to_lower()
		# prepare_svg.py's own intermediate, not a source file.
		if base == "trimmed" or base.ends_with("_trimmed") or base.begins_with("_"):
			continue
		usable.append(c)
	if usable.is_empty():
		return ""
	var want := folder_name.to_lower()
	for c in usable:
		if c.get_basename().to_lower() == want:
			return song_folder.path_join(c)
	usable.sort()
	return song_folder.path_join(usable[0])


func _generate_audio_from_musicxml(xml_path: String, wav_path: String) -> void:
	var midi_path := wav_path.get_base_dir().path_join("generated_audio.mid")
	var mid_code := _run_python(["-u", _script_path("musicxml_to_midi.py"), xml_path, midi_path])
	if mid_code != 0:
		%StatusLabel.text = "musicxml_to_midi.py failed (exit %d)" % mid_code
		return
	if FileAccess.file_exists(midi_path):
		var wav_code := _run_python(["-u", _script_path("midi_to_wav.py"), midi_path, wav_path])
		if wav_code != 0:
			%StatusLabel.text = "midi_to_wav.py failed (exit %d)" % wav_code
			return
		DirAccess.remove_absolute(midi_path)


# OS.execute only hands back stdout, so the Python steps print their diagnostics
# there (see prepare_svg.py) and we surface the tail of it. A bare "exit 1" with
# no output made a prepare failure impossible to diagnose from the app.
func _run_python(args: PackedStringArray) -> int:
	var out: Array = []
	var code: int = OS.execute(_python_exe(), args, out, true)
	python_log.clear()
	for line in out:
		var text := str(line).strip_edges()
		if not text.is_empty():
			python_log.append(text)
	if code != 0:
		for line in python_log:
			push_error("python: " + line)
	return code


func _prepare_assets_async() -> void:
	prepare_thread = Thread.new()
	prepare_thread.start(_prepare_assets)


func _prepare_assets() -> void:
	var output_dir := song_folder
	var script := _script_path("prepare_svg.py")
	var args: PackedStringArray = [script, svg_path, output_dir, xml_path]
	prepare_exit_code = _run_python(args)
	call_deferred("_on_prepare_done")


func _on_prepare_done() -> void:
	if prepare_thread:
		prepare_thread.wait_to_finish()
		prepare_thread = null
	var json_path := song_folder.path_join("result.json")
	if prepare_exit_code != 0 or not FileAccess.file_exists(json_path):
		# Show whatever the script managed to say, so the failure is readable
		# without opening a terminal.
		var detail: String = " (see output log)" if python_log.is_empty() else ": " + python_log[python_log.size() - 1]
		%StatusLabel.text = "Preparation failed (python exit %d)%s" % [prepare_exit_code, detail]
		return
	var file := FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		%StatusLabel.text = "Cannot read result.json"
		return
	var json_text := file.get_as_text()
	file.close()
	var json := JSON.new()
	var err := json.parse(json_text)
	if err != OK:
		%StatusLabel.text = "JSON parse error"
		return
	var data: Dictionary = json.data
	last_trim_data = data.get("trim", {})
	note_positions = data.get("notes", [])
	scroll_map = data.get("scroll_map", [])
	tile_paths = []
	for p in data.get("tile_paths", []):
		tile_paths.append(_asset_path(p))
	tile_widths_svg = data.get("tile_widths", [])
	sheet_png_path = _asset_path(data.get("png", ""))
	if sheet_png_path.is_empty() or not FileAccess.file_exists(sheet_png_path):
		%StatusLabel.text = "Sheet PNG not found"
		return
	%StatusLabel.text = "Ready - %d notes" % note_positions.size()
	_warn_on_duration_mismatch()
	%ExportBtn.disabled = false
	%PreviewBtn.disabled = false


# The audio and the score are authored separately, so they drift apart. A short
# audio file used to look like the renderer looping the track at the end.
func _warn_on_duration_mismatch() -> void:
	var audio_len: float = _audio_length()
	if audio_len <= 0.0:
		return
	var score_len: float = float(_build_xml_data().get("total_time", 0.0))
	if score_len <= 0.0:
		return
	var diff: float = audio_len - score_len
	if absf(diff) <= 0.5:
		return
	var which := "shorter" if diff < 0.0 else "longer"
	var msg := "audio is %.1fs %s than the score" % [absf(diff), which]
	%StatusLabel.text = "Ready - " + msg
	push_warning("boomwhacker: " + msg + " (audio %.2fs, score %.2fs)" % [audio_len, score_len])


func _audio_length() -> float:
	if audio_path.is_empty() or not FileAccess.file_exists(audio_path):
		return 0.0
	var stream: AudioStream = null
	match audio_path.get_extension().to_lower():
		"mp3":
			stream = AudioStreamMP3.load_from_file(audio_path)
		"wav":
			stream = AudioStreamWAV.load_from_file(audio_path)
		"ogg":
			stream = AudioStreamOggVorbia.load_from_file(audio_path)
	if stream == null:
		return 0.0
	return stream.get_length()


func _build_xml_data() -> Dictionary:
	if not cached_xml_data.is_empty():
		return cached_xml_data
	var parser := MusicXMLParserClass.new()
	parser.parse(xml_path)
	cached_xml_data = {
		"tempo": parser.get_tempo(),
		"total_time": parser.get_total_time(),
		"beats": parser.beats,
		"divisions": parser.divisions,
		"beats_per_measure": parser.beats_per_measure,
		"beat_type": parser.beat_type,
	}
	return cached_xml_data


func _build_colour_map() -> ColourMapClass:
	var colour_map := ColourMapClass.new()
	if not colours_path.is_empty():
		colour_map.load_from_file(colours_path)
	return colour_map


func _on_export() -> void:
	if sheet_png_path.is_empty() or xml_path.is_empty():
		%StatusLabel.text = "Need SVG + MusicXML"
		return
	var xml_data := _build_xml_data()
	var colour_map := _build_colour_map()
	var sname: String = %SongName.text.strip_edges()
	if sname.is_empty():
		sname = song_folder.get_file()
	var aname: String = %ArtistName.text.strip_edges()
	var render_scene := preload("res://scenes/video_renderer.tscn").instantiate()
	add_child(render_scene)
	render_scene.visible = false
	active_render_scene = render_scene
	render_scene.setup(sheet_png_path, xml_data, colour_map, sname, aname, audio_path, song_folder, last_trim_data, note_positions, scroll_map, tile_paths, tile_widths_svg)
	render_scene.progress.connect(func(p): %Progress.value = p * 100)
	render_scene.done.connect(_on_render_done)
	%StatusLabel.text = "Exporting..."
	%ExportBtn.disabled = true
	%PreviewBtn.disabled = true
	%CancelBtn.disabled = false
	render_scene.start_export()


func _on_preview() -> void:
	if sheet_png_path.is_empty() or xml_path.is_empty():
		%StatusLabel.text = "Need SVG + MusicXML"
		return
	var xml_data := _build_xml_data()
	var colour_map := _build_colour_map()
	var sname: String = %SongName.text.strip_edges()
	if sname.is_empty():
		sname = song_folder.get_file()
	var aname: String = %ArtistName.text.strip_edges()
	var render_scene := preload("res://scenes/video_renderer.tscn").instantiate()
	add_child(render_scene)
	render_scene.setup(sheet_png_path, xml_data, colour_map, sname, aname, audio_path, song_folder, last_trim_data, note_positions, scroll_map, tile_paths, tile_widths_svg)
	active_render_scene = render_scene
	%StatusLabel.text = "Previewing... (Cancel stops it)"
	%PreviewBtn.disabled = true
	%CancelBtn.disabled = false
	render_scene.start_preview()


func _on_render_done(msg: String) -> void:
	%StatusLabel.text = msg
	%ExportBtn.disabled = false
	%PreviewBtn.disabled = false
	%CancelBtn.disabled = true
	if active_render_scene != null and is_instance_valid(active_render_scene):
		active_render_scene.queue_free()
	active_render_scene = null


# Export and preview both look frozen from the outside, so give the operator a way
# out that is not "quit the app and hope the scratch folders got cleaned up".
func _on_cancel() -> void:
	if active_render_scene == null or not is_instance_valid(active_render_scene):
		return
	%StatusLabel.text = "Stopping..."
	%CancelBtn.disabled = true
	active_render_scene.cancel()
