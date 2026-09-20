extends Control

const MusicXMLParserClass = preload("res://scripts/musicxml_parser.gd")
const ColourMapClass = preload("res://scripts/colour_map.gd")

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
var dir_dialog: FileDialog
var prepare_thread: Thread


func _ready() -> void:
	%PickFolder.pressed.connect(_on_pick_folder)
	%ExportBtn.pressed.connect(_on_export)
	%ExportBtn.disabled = true
	%PreviewBtn.pressed.connect(_on_preview)
	%PreviewBtn.disabled = true
	dir_dialog = FileDialog.new()
	dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dir_dialog.access = FileDialog.ACCESS_FILESYSTEM
	dir_dialog.title = "Select Song Folder"
	dir_dialog.dir_selected.connect(_on_dir_selected)
	add_child(dir_dialog)


func _on_pick_folder() -> void:
	dir_dialog.popup_centered(Vector2i(800, 600))


func _on_dir_selected(dir: String) -> void:
	song_folder = dir
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
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not fname.begins_with("."):
			var full := song_folder.path_join(fname)
			match fname.get_extension().to_lower():
				"svg":
					svg_path = full
				"musicxml", "xml":
					xml_path = full
				"mp3", "wav", "ogg":
					audio_path = full
				"png", "jpg", "jpeg":
					if fname.get_file().to_lower().begins_with("cover"):
						cover_path = full
				"txt":
					if fname.get_file().to_lower().begins_with("colour") or fname.get_file().to_lower().begins_with("color"):
						colours_path = full
		fname = dir.get_next()
	dir.list_dir_end()
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


func _generate_audio_from_musicxml(xml_path: String, wav_path: String) -> void:
	var python := "C:/Users/Will/AppData/Local/Python/pythoncore-3.14-64/python.exe"
	var midi_path := wav_path.get_base_dir().path_join("generated_audio.mid")
	var script_dir := "C:/Users/Will/Documents/boomwhacker/scripts"
	OS.execute(python, [script_dir + "/musicxml_to_midi.py", xml_path, midi_path], [], true)
	if FileAccess.file_exists(midi_path):
		OS.execute(python, [script_dir + "/midi_to_wav.py", midi_path, wav_path], [], true)
		DirAccess.remove_absolute(midi_path)


func _prepare_assets_async() -> void:
	prepare_thread = Thread.new()
	prepare_thread.start(_prepare_assets)


func _prepare_assets() -> void:
	var output_dir := song_folder
	var python := "C:/Users/Will/AppData/Local/Python/pythoncore-3.14-64/python.exe"
	var script := "C:/Users/Will/Documents/boomwhacker/scripts/prepare_svg.py"
	var args: PackedStringArray = [script, svg_path, output_dir, xml_path]
	OS.execute(python, args, [], true)
	call_deferred("_on_prepare_done")


func _on_prepare_done() -> void:
	if prepare_thread:
		prepare_thread.wait_to_finish()
		prepare_thread = null
	var json_path := song_folder.path_join("result.json")
	if not FileAccess.file_exists(json_path):
		%StatusLabel.text = "Preparation failed"
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
	sheet_png_path = data.get("png", "")
	if not FileAccess.file_exists(sheet_png_path):
		%StatusLabel.text = "Sheet PNG not found"
		return
	%StatusLabel.text = "Ready - %d notes" % note_positions.size()
	%ExportBtn.disabled = false
	%PreviewBtn.disabled = false


func _build_xml_data() -> Dictionary:
	var parser := MusicXMLParserClass.new()
	parser.parse(xml_path)
	return {
		"tempo": parser.get_tempo(),
		"total_time": parser.get_total_time(),
		"beats": parser.beats,
		"divisions": parser.divisions,
		"beats_per_measure": parser.beats_per_measure,
		"beat_type": parser.beat_type,
	}


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
	render_scene.setup(sheet_png_path, xml_data, colour_map, sname, aname, audio_path, song_folder, last_trim_data, note_positions, scroll_map)
	render_scene.progress.connect(func(p): %Progress.value = p * 100)
	render_scene.done.connect(func(msg): %StatusLabel.text = msg; %ExportBtn.disabled = false; %PreviewBtn.disabled = false; render_scene.queue_free())
	%StatusLabel.text = "Exporting..."
	%ExportBtn.disabled = true
	%PreviewBtn.disabled = true
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
	render_scene.setup(sheet_png_path, xml_data, colour_map, sname, aname, audio_path, song_folder, last_trim_data, note_positions, scroll_map)
	%StatusLabel.text = "Previewing..."
	%PreviewBtn.disabled = true
	render_scene.start_preview()
