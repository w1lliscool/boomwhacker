extends Control

signal progress(value: float)
signal done(message: String)

var sheet_png_path: String
var xml_data: Dictionary
var song_name: String
var artist_name: String
var audio_path: String
var output_folder: String
var trim_data: Dictionary
var note_positions: Array
var prebuilt_scroll_map: Array

var total_duration: float
var viewport_w: float = 1920.0
var viewport_h: float = 1080.0

var svg_content_w: float = 0.0
var strip_pixel_w: float = 0.0
var strip_pixel_h: float = 0.0
var svg_to_pixel: float = 1.0
var scroll_map: Array = []
var _sheet_shader: ShaderMaterial = null
var _preview_mode: bool = false
var _current_time: float = 0.0

var intro_bg_fade: float = 0.5
var intro_card_fade: float = 0.8
var intro_blur_in: float = 1.5
var intro_total: float = 6.8
var outro_duration: float = 3.0
var total_video_time: float = 0.0
var framerate: float = 60.0

@onready var sub_viewport: SubViewport = %SubViewport
@onready var music_strip: TextureRect = %MusicStrip
@onready var intro_card: Control = %IntroCard
@onready var title_label: Label = %TitleLabel
@onready var artist_label: Label = %ArtistLabel
@onready var scroller_line: ColorRect = %ScrollerLine
@onready var cover_tex: TextureRect = %CoverTex
@onready var duration_label: Label = %DurationLabel
@onready var background: TextureRect = %BGTex
@onready var fade_to_black: ColorRect = %FadeToBlack
@onready var audio_player: AudioStreamPlayer = %AudioPlayer


func setup(p_png_path: String, p_xml_data: Dictionary, _p_colour_map, p_song_name: String, p_artist_name: String, p_audio_path: String, p_output_folder: String, p_trim_data: Dictionary = {}, p_note_positions: Array = [], p_scroll_map: Array = []) -> void:
	sheet_png_path = p_png_path
	xml_data = p_xml_data
	song_name = p_song_name
	artist_name = p_artist_name
	audio_path = p_audio_path
	output_folder = p_output_folder
	trim_data = p_trim_data
	note_positions = p_note_positions
	prebuilt_scroll_map = p_scroll_map
	total_duration = xml_data.get("total_time", 0.0)
	svg_content_w = trim_data.get("width", 1.0)
	_load_sheet_texture()
	_build_scroll_map()
	_load_audio()
	if scroll_map.size() > 0:
		total_duration = scroll_map.back().get("time", total_duration)
	total_video_time = intro_total + total_duration + outro_duration
	_setup_intro_card()
	_load_background()


func start_export() -> void:
	_export_all_frames()


func start_preview() -> void:
	visible = true
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_preview_mode = true
	_current_time = 0.0


func _process(delta: float) -> void:
	if _preview_mode:
		_current_time += delta
		_apply_frame(_current_time)
		if _current_time >= total_video_time:
			_preview_mode = false
			audio_player.stop()
		elif _current_time >= intro_total and not audio_player.playing and audio_player.stream:
			audio_player.play()
		elif _current_time < intro_total and audio_player.playing:
			audio_player.stop()


func _load_sheet_texture() -> void:
	var img := Image.load_from_file(sheet_png_path)
	if img == null:
		push_error("Failed to load sheet PNG: " + sheet_png_path)
		return
	var target_h: float = viewport_h * 0.7
	var scale_factor: float = target_h / float(img.get_height())
	var new_w: int = int(float(img.get_width()) * scale_factor)
	var new_h: int = int(target_h)
	img.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)
	strip_pixel_w = float(new_w)
	strip_pixel_h = float(new_h)
	svg_to_pixel = strip_pixel_w / svg_content_w
	var tex := ImageTexture.create_from_image(img)
	music_strip.texture = tex
	music_strip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	music_strip.stretch_mode = TextureRect.STRETCH_SCALE
	music_strip.offset_top = (viewport_h - strip_pixel_h) / 2.0
	music_strip.offset_bottom = music_strip.offset_top + strip_pixel_h
	music_strip.offset_left = 0.0
	music_strip.offset_right = viewport_w
	var shader := preload("res://shaders/sheet_scroll.gdshader")
	_sheet_shader = ShaderMaterial.new()
	_sheet_shader.shader = shader
	_sheet_shader.set_shader_parameter("sheet_texture", tex)
	_sheet_shader.set_shader_parameter("strip_w", strip_pixel_w)
	_sheet_shader.set_shader_parameter("strip_h", strip_pixel_h)
	_sheet_shader.set_shader_parameter("scroll_x", 0.0)
	music_strip.material = _sheet_shader


func _build_scroll_map() -> void:
	scroll_map.clear()
	if prebuilt_scroll_map.size() > 0:
		for entry in prebuilt_scroll_map:
			scroll_map.append({"time": entry.get("time", 0.0), "x": entry.get("x", 0.0) * svg_to_pixel})
		return
	if note_positions.size() == 0:
		return
	var first_x: float = note_positions[0].get("x", 0.0) * svg_to_pixel
	var last_x: float = note_positions[note_positions.size() - 1].get("x", 0.0) * svg_to_pixel
	scroll_map.append({"time": 0.0, "x": first_x})
	scroll_map.append({"time": total_duration, "x": last_x})


func _get_scroll_pixel(t: float) -> float:
	if scroll_map.size() == 0:
		return 0.0
	if t <= scroll_map[0].time:
		return scroll_map[0].x
	if t >= scroll_map[scroll_map.size() - 1].time:
		return scroll_map[scroll_map.size() - 1].x
	for i in range(scroll_map.size() - 1):
		var a: Dictionary = scroll_map[i]
		var b: Dictionary = scroll_map[i + 1]
		if t >= a.time and t <= b.time:
			var dt: float = b.time - a.time
			if dt < 0.0001:
				return a.x
			var frac: float = (t - a.time) / dt
			return a.x + frac * (b.x - a.x)
	return scroll_map[scroll_map.size() - 1].x


func _setup_intro_card() -> void:
	title_label.text = song_name
	artist_label.text = artist_name
	var mins := int(total_duration / 60.0)
	var secs := int(total_duration) % 60
	duration_label.text = "%d:%02d" % [mins, secs]
	intro_card.visible = true
	intro_card.modulate = Color(1, 1, 1, 0)
	var cover_path := output_folder.path_join("cover.png")
	if FileAccess.file_exists(cover_path):
		var cover_img := Image.load_from_file(cover_path)
		if cover_img:
			cover_img.resize(200, 200, Image.INTERPOLATE_BILINEAR)
			cover_tex.texture = ImageTexture.create_from_image(cover_img)


func _load_background() -> void:
	var bg_path := output_folder.path_join("background.png")
	if FileAccess.file_exists(bg_path):
		var bg_img := Image.load_from_file(bg_path)
		if bg_img:
			bg_img.resize(1920, 1080, Image.INTERPOLATE_BILINEAR)
			background.texture = ImageTexture.create_from_image(bg_img)


func _load_audio() -> void:
	if audio_path.is_empty() or not FileAccess.file_exists(audio_path):
		return
	var ext := audio_path.get_extension().to_lower()
	if ext == "mp3":
		audio_player.stream = AudioStreamMP3.load_from_file(audio_path)
	elif ext == "wav":
		audio_player.stream = AudioStreamWAV.load_from_file(audio_path)
	elif ext == "ogg":
		audio_player.stream = AudioStreamOggVorbis.load_from_file(audio_path)
	if audio_player.stream:
		var audio_len: float = audio_player.stream.get_length()
		if audio_len > total_duration:
			total_duration = audio_len


func _export_all_frames() -> void:
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var total_frames := int(total_video_time * framerate) + 1
	var temp_dir := output_folder.path_join("_temp_frames")
	DirAccess.make_dir_recursive_absolute(temp_dir)
	for frame in range(total_frames):
		var t := float(frame) / framerate
		_apply_frame(t)
		await get_tree().process_frame
		var img := sub_viewport.get_texture().get_image()
		img.save_jpg(temp_dir.path_join("frame_%06d.jpg" % frame), 0.9)
		progress.emit(float(frame) / float(total_frames) * 0.85)
	_encode_video(temp_dir, total_frames)


func _apply_frame(t: float) -> void:
	_apply_intro(t)
	_apply_music_strip(t)
	_apply_overlay(t)


func _apply_intro(t: float) -> void:
	var card_alpha := 0.0
	if t >= intro_bg_fade and t < intro_bg_fade + 0.3:
		card_alpha = (t - intro_bg_fade) / 0.3
		intro_card.visible = true
		intro_card.modulate = Color(1, 1, 1, card_alpha)
	elif t >= intro_bg_fade + 0.3 and t < intro_total - intro_card_fade:
		card_alpha = 1.0
		intro_card.visible = true
		intro_card.modulate = Color.WHITE
	elif t >= intro_total - intro_card_fade and t < intro_total:
		card_alpha = 1.0 - (t - (intro_total - intro_card_fade)) / intro_card_fade
		intro_card.visible = true
		intro_card.modulate = Color(1, 1, 1, card_alpha)
	else:
		intro_card.visible = false

	var sheet_alpha := clampf((t - intro_total + 0.5) / 0.5, 0.0, 1.0) if t >= intro_total - 0.5 else 0.0
	music_strip.modulate.a = sheet_alpha


func _apply_music_strip(t: float) -> void:
	if t < intro_total:
		if _sheet_shader:
			_sheet_shader.set_shader_parameter("scroll_x", -1.0)
		return
	var scroll_t := t - intro_total
	var current_pixel: float = _get_scroll_pixel(scroll_t)
	var center_offset: float = current_pixel - (viewport_w / 2.0)
	var scroll_frac: float = center_offset / strip_pixel_w
	if _sheet_shader:
		_sheet_shader.set_shader_parameter("scroll_x", scroll_frac)


func _apply_overlay(t: float) -> void:
	scroller_line.visible = t >= intro_total and t < intro_total + total_duration
	if scroller_line.visible:
		scroller_line.position = Vector2(957.0, 0)
		scroller_line.size = Vector2(6.0, viewport_h)
	var music_end := intro_total + total_duration
	var fade_black := 0.0
	if t > music_end:
		fade_black = clampf((t - music_end) / outro_duration, 0.0, 1.0)
	fade_to_black.color = Color(0, 0, 0, fade_black)


func _encode_video(temp_dir: String, _total_frames: int) -> void:
	progress.emit(0.9)
	var output_path := output_folder.path_join(song_name.replace(" ", "_") + ".mp4")
	var frame_pattern := temp_dir.path_join("frame_%06d.jpg")
	var args: PackedStringArray = [
		"-framerate", str(framerate),
		"-i", frame_pattern,
		"-c:v", "libx264",
		"-pix_fmt", "yuv420p",
		"-preset", "ultrafast",
		"-crf", "23",
		"-y", output_path
	]
	if audio_path != "" and FileAccess.file_exists(audio_path):
		args = PackedStringArray([
			"-framerate", str(framerate),
			"-i", frame_pattern,
			"-i", audio_path,
			"-c:v", "libx264",
			"-pix_fmt", "yuv420p",
			"-preset", "ultrafast",
			"-crf", "23",
			"-shortest",
			"-y", output_path
		])
	var exit_code := OS.execute("C:/Users/Will/Documents/ffmpeg/bin/ffmpeg.exe", args, [], true)
	_cleanup_temp_frames(temp_dir)
	progress.emit(1.0)
	if exit_code == 0:
		done.emit("Exported to " + output_path)
	else:
		done.emit("FFmpeg failed with code " + str(exit_code))


func _cleanup_temp_frames(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d:
		d.list_dir_begin()
		var fn := d.get_next()
		while fn != "":
			if not d.current_is_dir():
				d.remove(fn)
			fn = d.get_next()
		d.list_dir_end()
		DirAccess.remove_absolute(dir)
