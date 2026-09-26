extends Control

const ScrollMath = preload("res://scripts/scroll_math.gd")

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
var tile_paths: Array
var tile_widths_svg: Array

var total_duration: float
var viewport_w: float = 1920.0
var viewport_h: float = 1080.0
var render_scale: float = 4.0 / 3.0
var _layout_scale: float = 1.0
var _resolution_applied: bool = false
var _cover_img: Image = null

var svg_content_w: float = 0.0
var strip_pixel_w: float = 0.0
var strip_pixel_h: float = 0.0
var svg_to_pixel: float = 1.0
var scroll_map: Array = []
var _preview_mode: bool = false
var _current_time: float = 0.0
var _audio_started: bool = false
var _clicks_started: bool = false
var _click_player: AudioStreamPlayer = null
var _click_stream: AudioStreamWAV = null
var _click_path: String = ""
# After the last note the score keeps travelling: on to the closing double bar
# line over this many beats, then on at the same rate while the video fades out.
var tail_beats: int = 4
var end_bar_x: float = 0.0
var tail_rate: float = 0.0

var tile_textures: Array = []
var tile_pixel_widths: Array = []
var tile_base_x: Array = []
var total_pixel_width: float = 0.0
var keep_start: int = 250
var anchor_times: Array = []
var anchor_x: Array = []
var anchor_tangent: Array = []

var intro_bg_fade: float = 0.5
var intro_card_fade: float = 0.8
var intro_blur_in: float = 1.5
var intro_total: float = 6.8
# Counted in at the song's own tempo, so the numbers land on real beats and the
# first note meets the playhead exactly as the audio starts.
var count_in_beats: int = 4
var beat_seconds: float = 0.5
var count_in_time: float = 2.0
var count_in_start: float = 4.8
# The song is already scrolling when the numbers start, so it fades in with the
# first beat instead of waiting for the music.
var count_in_fade: float = 0.6
# Metronome level in dBFS. The song peaks near -17 dBFS, so the clicks sit just
# under it rather than blasting out of an otherwise silent intro.
var click_gain_db: float = -22.0
var click_accent_db: float = 5.0
# The song's own opening scroll speed, in sheet pixels per second. The count-in
# runs at exactly this rate so there is no jump when the music starts.
var entry_rate: float = 0.0
var outro_duration: float = 3.0
var total_video_time: float = 0.0
var framerate: float = 60.0
# Frames are encoded a few seconds at a time instead of all at once, so a long
# song never needs more than a few hundred MB of scratch space on disk.
var chunk_frames: int = 240
var _chunk_dir: String = ""
var _chunk_index: int = 0
var _chunk_count: int = 0
var _pending_pid: int = -1
var _pending_chunk: int = -1
var _pending_count: int = 0
var _pending_start: int = 0
var _frames_written: int = 0
var _prev_vsync: int = DisplayServer.VSYNC_ENABLED
var _chunk_error: int = 0
var _encode_task: int = -1
var _cancel: bool = false

@onready var sub_viewport: SubViewport = %SubViewport
@onready var viewport_container: SubViewportContainer = %SubViewportContainer
@onready var hbox: HBoxContainer = %HBox
@onready var music_strip: TextureRect = %MusicStrip
@onready var pinned_start: TextureRect = %PinnedStart
@onready var pinned_divider: ColorRect = %PinnedDivider
@onready var intro_card: Control = %IntroCard
@onready var title_label: Label = %TitleLabel
@onready var artist_label: Label = %ArtistLabel
@onready var scroller_line: ColorRect = %ScrollerLine
@onready var count_in_label: Label = %CountInLabel
@onready var cover_tex: TextureRect = %CoverTex
@onready var duration_label: Label = %DurationLabel
@onready var background: TextureRect = %BGTex
@onready var background_blur: TextureRect = %BGTexBlur
@onready var fade_to_black: ColorRect = %FadeToBlack
@onready var audio_player: AudioStreamPlayer = %AudioPlayer
@onready var glass_panel: PanelContainer = %GlassPanel
@onready var divider_line: ColorRect = %DividerLine


func setup(p_png_path: String, p_xml_data: Dictionary, _p_colour_map, p_song_name: String, p_artist_name: String, p_audio_path: String, p_output_folder: String, p_trim_data: Dictionary = {}, p_note_positions: Array = [], p_scroll_map: Array = [], p_tile_paths: Array = [], p_tile_widths_svg: Array = [], p_keep_start: float = 250.0) -> void:
	sheet_png_path = p_png_path
	xml_data = p_xml_data
	song_name = p_song_name
	artist_name = p_artist_name
	audio_path = p_audio_path
	output_folder = p_output_folder
	trim_data = p_trim_data
	note_positions = p_note_positions
	prebuilt_scroll_map = p_scroll_map
	tile_paths = p_tile_paths
	tile_widths_svg = p_tile_widths_svg
	keep_start = int(clampf(p_keep_start, 0.0, 1920.0))
	total_duration = xml_data.get("total_time", 0.0)
	svg_content_w = trim_data.get("width", 1.0)
	_setup_count_in()
	_load_sheet_texture()
	_build_scroll_map()
	_setup_tail()
	_load_audio()
	if scroll_map.size() > 0:
		total_duration = maxf(total_duration, scroll_map.back().get("time", 0.0))
	total_video_time = intro_total + total_duration + outro_duration
	_setup_intro_card()
	_load_background()
	_apply_music_strip(intro_total)


func _setup_count_in() -> void:
	var sched := ScrollMath.count_in_schedule(
		float(xml_data.get("tempo", 120.0)), count_in_beats, intro_bg_fade, intro_card_fade, intro_total)
	beat_seconds = sched["beat_seconds"]
	count_in_time = sched["count_in_time"]
	intro_total = sched["intro_total"]
	count_in_start = sched["count_in_start"]
	_build_click_track()


func _db_to_amp(db: float) -> float:
	return ScrollMath.db_to_amp(db)


# Synthesises the count-in clicks instead of shipping an audio file, so they
# always match the detected tempo.
func _build_click_track() -> void:
	var rate := 44100
	var length: int = int(ceil(count_in_time * float(rate))) + rate / 20
	var samples := PackedFloat32Array()
	samples.resize(length)
	var decay: float = float(rate) * 0.055
	for b in count_in_beats:
		# Accent the first beat so the count-in has a clear "one".
		var freq: float = 1320.0 if b == 0 else 990.0
		var amp: float = _db_to_amp(click_gain_db if b == 0 else click_gain_db - click_accent_db)
		var at: int = int(round(float(b) * beat_seconds * float(rate)))
		var n: int = mini(int(decay * 3.0), length - at)
		for i in maxi(n, 0):
			var env: float = exp(-float(i) / decay)
			# A touch of second harmonic gives the tick some bite.
			var s: float = sin(TAU * freq * float(i) / float(rate)) * 0.82 \
				+ sin(TAU * freq * 2.0 * float(i) / float(rate)) * 0.18
			samples[at + i] = s * env * amp
	var data := PackedByteArray()
	data.resize(length * 2)
	for i in length:
		var v: int = int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	_click_stream = AudioStreamWAV.new()
	_click_stream.format = AudioStreamWAV.FORMAT_16_BITS
	_click_stream.mix_rate = rate
	_click_stream.stereo = false
	_click_stream.data = data


func _ensure_click_player() -> void:
	if _click_player != null or _click_stream == null:
		return
	_click_player = AudioStreamPlayer.new()
	_click_player.stream = _click_stream
	add_child(_click_player)


func start_export() -> void:
	_cancel = false
	_set_render_resolution(render_scale)
	# Nobody is watching the window during an offline capture, so drop the frame
	# pacing and let the loop run as fast as the machine can manage.
	_prev_vsync = DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_export_all_frames()


# A full export is a long, uninterruptible-looking job, so give the caller a way
# out that does not mean quitting the app and losing the scratch folders.
func cancel() -> void:
	_cancel = true
	if _preview_mode:
		_preview_mode = false
		visible = false
		done.emit("Preview stopped")


func _abort_export() -> void:
	# ffmpeg is still writing into the chunk folder, so it has to die before the
	# folder is cleared, otherwise it recreates the files behind our back.
	if _pending_pid != -1:
		OS.kill(_pending_pid)
		_pending_pid = -1
	_drain_encode_task()
	_clear_dir(output_folder.path_join("_temp_frames"))
	_clear_dir(_chunk_dir)
	_finish_export()
	done.emit("Export cancelled")


func _finish_export() -> void:
	DisplayServer.window_set_vsync_mode(_prev_vsync)
	_prev_vsync = DisplayServer.VSYNC_ENABLED


func start_preview() -> void:
	_cancel = false
	# The preview just mirrors whatever the window is, so follow the container.
	_set_render_resolution(maxf(viewport_container.size.x, 1920.0) / 1920.0, true)
	visible = true
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_preview_mode = true
	_current_time = 0.0
	_audio_started = false
	_clicks_started = false


func _set_render_resolution(s: float, follow_container: bool = false) -> void:
	if is_equal_approx(_layout_scale, s) and _resolution_applied:
		return
	_layout_scale = s
	viewport_w = 1920.0 * s
	viewport_h = 1080.0 * s
	# With stretch enabled the container overwrites the viewport size to match
	# itself, so it has to be off for the export resolution to take effect.
	viewport_container.stretch = follow_container
	sub_viewport.size = Vector2i(int(viewport_w), int(viewport_h))
	_scale_layout(s)
	_resolution_applied = true


func _scale_layout(s: float) -> void:
	var m := 40.0 * s
	glass_panel.offset_left = -360.0 * s
	glass_panel.offset_top = -200.0 * s
	glass_panel.offset_right = 360.0 * s
	glass_panel.offset_bottom = 200.0 * s
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.05)
	sb.border_color = Color(1, 1, 1, 0.16)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(int(28.0 * s))
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = int(28.0 * s)
	sb.shadow_offset = Vector2(0, 12.0 * s)
	sb.content_margin_left = m
	sb.content_margin_right = m
	sb.content_margin_top = 34.0 * s
	sb.content_margin_bottom = 34.0 * s
	glass_panel.add_theme_stylebox_override("panel", sb)
	cover_tex.custom_minimum_size = Vector2(200, 200) * s
	divider_line.custom_minimum_size = Vector2(120, 3) * s
	hbox.add_theme_constant_override("separation", int(30.0 * s))
	title_label.add_theme_font_size_override("font_size", int(round(46.0 * s)))
	artist_label.add_theme_font_size_override("font_size", int(round(22.0 * s)))
	duration_label.add_theme_font_size_override("font_size", int(round(16.0 * s)))
	_apply_cover_texture()
	_load_sheet_texture()
	# Reloading the sheet changes svg_to_pixel, so the scroll positions and the
	# closing tail have to be rebuilt at the new scale.
	_build_scroll_map()
	_setup_tail()
	_load_background()


func _process(delta: float) -> void:
	if not _preview_mode:
		return
	_current_time += delta
	_apply_frame(_current_time)
	if _current_time >= total_video_time:
		_preview_mode = false
		audio_player.stop()
		return
	if _current_time < intro_total:
		if audio_player.playing:
			audio_player.stop()
	elif not _audio_started and audio_player.stream:
		# Start it once. The audio is shorter than the video, so "not playing"
		# becomes true again near the end and used to restart it from the top.
		_audio_started = true
		audio_player.play()
	if _current_time >= count_in_start and not _clicks_started:
		_clicks_started = true
		_ensure_click_player()
		if _click_player != null:
			_click_player.play()


func _load_sheet_texture() -> void:
	var target_h: float = viewport_h * 0.7
	strip_pixel_h = target_h
	tile_textures.clear()
	tile_pixel_widths.clear()
	tile_base_x.clear()
	total_pixel_width = 0.0
	var paths: Array = tile_paths if tile_paths.size() > 0 else [sheet_png_path]
	for i in range(paths.size()):
		var img := Image.load_from_file(paths[i])
		if img == null:
			continue
		var scale_factor: float = target_h / float(img.get_height())
		var new_w: int = int(float(img.get_width()) * scale_factor)
		var new_h: int = int(target_h)
		img.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)
		var tex := ImageTexture.create_from_image(img)
		tile_textures.append(tex)
		tile_pixel_widths.append(float(new_w))
		total_pixel_width += float(new_w)
	strip_pixel_w = total_pixel_width
	svg_to_pixel = strip_pixel_w / svg_content_w if svg_content_w > 0 else 1.0
	music_strip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	music_strip.stretch_mode = TextureRect.STRETCH_SCALE
	music_strip.offset_top = (viewport_h - strip_pixel_h) / 2.0
	music_strip.offset_bottom = music_strip.offset_top + strip_pixel_h
	music_strip.offset_left = 0.0
	music_strip.offset_right = viewport_w
	music_strip.clip_contents = true
	for child in music_strip.get_children():
		music_strip.remove_child(child)
		child.queue_free()
	if tile_textures.size() == 0:
		return

	var auto_pin := -1.0
	if note_positions.size() > 0:
		var min_note_x: float = 1.0e18
		for n in note_positions:
			min_note_x = minf(min_note_x, n.get("x", 0.0))
		if min_note_x < 1.0e17:
			auto_pin = min_note_x * svg_to_pixel - 10.0
	if auto_pin >= 0.0:
		keep_start = int(clampf(auto_pin, 0.0, tile_pixel_widths[0]))
	else:
		keep_start = int(clampf(float(keep_start), 0.0, tile_pixel_widths[0]))
	music_strip.offset_left = float(keep_start)
	music_strip.offset_right = viewport_w
	pinned_start.offset_left = 0.0
	pinned_start.offset_right = float(keep_start)
	pinned_start.offset_top = music_strip.offset_top
	pinned_start.offset_bottom = music_strip.offset_bottom
	if keep_start > 0:
		var pin_tex := AtlasTexture.new()
		pin_tex.atlas = tile_textures[0]
		pin_tex.region = Rect2(0, 0, keep_start, int(strip_pixel_h))
		pinned_start.texture = pin_tex
		pinned_start.texture_filter = TextureRect.TEXTURE_FILTER_LINEAR
		pinned_start.visible = true
		pinned_divider.position = Vector2(float(keep_start) - 4.0, music_strip.offset_top)
		pinned_divider.size = Vector2(4.0, strip_pixel_h)
		pinned_divider.visible = true
	else:
		pinned_start.texture = null
		pinned_start.visible = false
		pinned_divider.visible = false

	var acc: float = 0.0
	for i in range(tile_textures.size()):
		var rect := TextureRect.new()
		var w: float = tile_pixel_widths[i]
		if i == 0 and keep_start > 0 and tile_pixel_widths[0] > float(keep_start):
			var sc_tex := AtlasTexture.new()
			sc_tex.atlas = tile_textures[0]
			sc_tex.region = Rect2(keep_start, 0, int(tile_pixel_widths[0]) - keep_start, int(strip_pixel_h))
			rect.texture = sc_tex
			w = tile_pixel_widths[0] - float(keep_start)
		else:
			rect.texture = tile_textures[i]
		rect.position = Vector2(acc, 0)
		rect.size = Vector2(w, strip_pixel_h)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		rect.texture_filter = TextureRect.TEXTURE_FILTER_LINEAR
		music_strip.add_child(rect)
		tile_base_x.append(acc)
		acc += w

func _build_scroll_map() -> void:
	scroll_map.clear()
	anchor_times.clear()
	anchor_x.clear()
	anchor_tangent.clear()
	if prebuilt_scroll_map.size() > 0:
		for entry in prebuilt_scroll_map:
			scroll_map.append({"time": entry.get("time", 0.0), "x": entry.get("x", 0.0) * svg_to_pixel})
	elif note_positions.size() > 0:
		var first_x: float = note_positions[0].get("x", 0.0) * svg_to_pixel
		var last_x: float = note_positions[note_positions.size() - 1].get("x", 0.0) * svg_to_pixel
		scroll_map.append({"time": 0.0, "x": first_x})
		scroll_map.append({"time": total_duration, "x": last_x})
	for e in scroll_map:
		if anchor_times.size() == 0 or e.get("time", 0.0) > anchor_times[anchor_times.size() - 1]:
			anchor_times.append(e.get("time", 0.0))
			anchor_x.append(e.get("x", 0.0))
		elif e.get("x", 0.0) < anchor_x[anchor_x.size() - 1]:
			anchor_x[anchor_x.size() - 1] = e.get("x", 0.0)
	_build_anchor_tangents()


func _setup_tail() -> void:
	# The closing double bar line is the right hand edge of the sheet.
	end_bar_x = strip_pixel_w
	tail_rate = 0.0
	# The tangent on the first anchor is the speed the piece actually starts at.
	entry_rate = maxf(anchor_tangent[0], 0.0) if anchor_tangent.size() > 0 else 0.0
	if entry_rate <= 0.0 and scroll_map.size() >= 2:
		var a: Dictionary = scroll_map[0]
		var b: Dictionary = scroll_map[1]
		var dt: float = b.get("time", 0.0) - a.get("time", 0.0)
		if dt > 0.0:
			entry_rate = maxf((b.get("x", 0.0) - a.get("x", 0.0)) / dt, 0.0)
	var tail_time := float(tail_beats) * beat_seconds
	if scroll_map.size() == 0 or tail_time <= 0.0:
		return
	var last: Dictionary = scroll_map[scroll_map.size() - 1]
	tail_rate = ScrollMath.tail_rate_for(last.get("x", 0.0), end_bar_x, tail_beats, beat_seconds)


func _build_anchor_tangents() -> void:
	anchor_tangent.clear()
	var n := anchor_times.size()
	if n == 0:
		return
	for i in range(n):
		anchor_tangent.append(0.0)
	if n < 2:
		return
	var delta: Array = []
	for i in range(n - 1):
		var dt: float = anchor_times[i + 1] - anchor_times[i]
		if dt < 1e-6:
			delta.append(0.0)
		else:
			delta.append((anchor_x[i + 1] - anchor_x[i]) / dt)
	anchor_tangent[0] = delta[0]
	anchor_tangent[n - 1] = delta[n - 2]
	for i in range(1, n - 1):
		if delta[i - 1] * delta[i] < 0.0:
			anchor_tangent[i] = 0.0
		else:
			anchor_tangent[i] = (delta[i - 1] + delta[i]) / 2.0
	for i in range(n - 1):
		if delta[i] == 0.0:
			anchor_tangent[i] = 0.0
			anchor_tangent[i + 1] = 0.0
			continue
		var alpha: float = anchor_tangent[i] / delta[i]
		var beta: float = anchor_tangent[i + 1] / delta[i]
		var sq: float = alpha * alpha + beta * beta
		if sq > 9.0:
			var s: float = 3.0 / sqrt(sq)
			anchor_tangent[i] = s * delta[i] * alpha
			anchor_tangent[i + 1] = s * delta[i] * beta


func _get_scroll_pixel(t: float) -> float:
	var n := anchor_times.size()
	if n == 0:
		return 0.0
	if t <= anchor_times[0]:
		return anchor_x[0]
	if t >= anchor_times[n - 1]:
		return anchor_x[n - 1]
	var i := 0
	while i < n - 2 and t > anchor_times[i + 1]:
		i += 1
	var t0: float = anchor_times[i]
	var t1: float = anchor_times[i + 1]
	var span: float = t1 - t0
	if span < 1e-6:
		return anchor_x[i]
	var u: float = (t - t0) / span
	var u2 := u * u
	var u3 := u2 * u
	var h00 := 2.0 * u3 - 3.0 * u2 + 1.0
	var h10 := u3 - 2.0 * u2 + u
	var h01 := -2.0 * u3 + 3.0 * u2
	var h11 := u3 - u2
	return h00 * anchor_x[i] + h10 * anchor_tangent[i] * span \
		+ h01 * anchor_x[i + 1] + h11 * anchor_tangent[i + 1] * span


func _setup_intro_card() -> void:
	title_label.text = song_name
	artist_label.text = artist_name
	var mins := int(total_duration / 60.0)
	var secs := int(total_duration) % 60
	duration_label.text = "%d:%02d" % [mins, secs]
	intro_card.visible = true
	intro_card.modulate = Color(1, 1, 1, 0)

	var bg_grad := Gradient.new()
	bg_grad.set_color(0, Color(0.05, 0.05, 0.055))
	bg_grad.set_color(1, Color(0.11, 0.105, 0.10))
	var bg_tex := GradientTexture2D.new()
	bg_tex.gradient = bg_grad
	bg_tex.fill = GradientTexture2D.FILL_LINEAR
	bg_tex.fill_from = Vector2(0.5, 0.0)
	bg_tex.fill_to = Vector2(0.5, 1.0)
	bg_tex.width = int(viewport_w)
	bg_tex.height = int(viewport_h)
	%IntroBG.texture = bg_tex

	var cover_path := output_folder.path_join("cover.png")
	if FileAccess.file_exists(cover_path):
		_cover_img = Image.load_from_file(cover_path)


func _apply_cover_texture() -> void:
	if _cover_img == null:
		return
	var side := int(200.0 * _layout_scale)
	var cover_img := _cover_img.duplicate()
	cover_img.resize(side, side, Image.INTERPOLATE_LANCZOS)
	cover_tex.texture = ImageTexture.create_from_image(cover_img)


func _load_background() -> void:
	var bg_path := output_folder.path_join("background.png")
	if not FileAccess.file_exists(bg_path):
		return
	var bg_img := Image.load_from_file(bg_path)
	if bg_img == null:
		return
	bg_img.resize(int(viewport_w), int(viewport_h), Image.INTERPOLATE_BILINEAR)
	background.texture = ImageTexture.create_from_image(bg_img)
	# Bake the blur once on the CPU. A per-frame gaussian shader over the full
	# frame costs ~34 texture fetches per pixel and dominates export frame time.
	# A hard lanczos downscale then upscale gives a smooth defocus for free.
	var blurred: Image = bg_img.duplicate()
	blurred.resize(int(viewport_w / 8.0), int(viewport_h / 8.0), Image.INTERPOLATE_LANCZOS)
	blurred.resize(int(viewport_w), int(viewport_h), Image.INTERPOLATE_LANCZOS)
	background_blur.texture = ImageTexture.create_from_image(blurred)


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
	var total_frames := int(total_video_time * framerate) + 1
	var temp_dir := output_folder.path_join("_temp_frames")
	_chunk_dir = output_folder.path_join("_temp_chunks")
	_clear_dir(temp_dir)
	_clear_dir(_chunk_dir)
	DirAccess.make_dir_recursive_absolute(temp_dir)
	DirAccess.make_dir_recursive_absolute(_chunk_dir)
	_chunk_index = 0
	_chunk_count = 0
	_chunk_error = 0
	_pending_count = 0
	_frames_written = 0
	_pending_start = 0
	for frame in range(total_frames):
		if _chunk_error != 0 or _cancel:
			break
		var t := float(frame) / framerate
		_apply_frame(t)
		# UPDATE_ONCE renders exactly one frame, and frame_post_draw fires once the
		# server has actually drawn it. Reading the texture any earlier captures the
		# previous frame, which would stretch the video and stall the scroll.
		sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		var img := sub_viewport.get_texture().get_image()
		# Frames are numbered for the whole export, not per chunk, so a chunk's
		# files can be deleted without touching the chunk being written right now.
		_save_frame(img, temp_dir.path_join("frame_%06d.jpg" % _frames_written))
		_frames_written += 1
		_chunk_count += 1
		if _chunk_count >= chunk_frames:
			await _flush_chunk(temp_dir)
		progress.emit(float(frame + 1) / float(total_frames) * 0.85)
	if _cancel:
		_abort_export()
		return
	if _chunk_error == 0 and _chunk_count > 0:
		await _flush_chunk(temp_dir)
	# The final chunk is still encoding, and the concat would read a half written
	# file, so block on it before handing over.
	await _wait_for_pending_chunk(temp_dir)
	if _chunk_error != 0:
		_drain_encode_task()
		_clear_dir(temp_dir)
		_clear_dir(_chunk_dir)
		_finish_export()
		done.emit("FFmpeg failed on chunk %d with code %d" % [_pending_chunk, _chunk_error])
		return
	_encode_video(_chunk_dir)


func _save_frame(img: Image, path: String) -> void:
	# JPEG encoding costs more than rendering the frame does, so push it to a
	# worker thread and let the next frame render while this one compresses.
	_drain_encode_task()
	var p := path
	_encode_task = WorkerThreadPool.add_task(func() -> void:
		img.save_jpg(p, 0.8))


func _drain_encode_task() -> void:
	if _encode_task != -1:
		WorkerThreadPool.wait_for_task_completion(_encode_task)
		_encode_task = -1


func _flush_chunk(temp_dir: String) -> void:
	# One encode at a time. Blocking here is what keeps the scratch folder down to
	# a single chunk, because the finished frames get deleted before the next
	# chunk starts writing over the same names.
	await _wait_for_pending_chunk(temp_dir)
	_drain_encode_task()
	if _chunk_error != 0:
		return
	_pending_chunk = _chunk_index
	_pending_count = _chunk_count
	_pending_start = _frames_written - _chunk_count
	_pending_pid = OS.create_process(_ffmpeg_path(), PackedStringArray([
		"-nostdin",
		"-loglevel", "error",
		"-framerate", str(framerate),
		"-start_number", str(_pending_start),
		"-i", temp_dir.path_join("frame_%06d.jpg"),
		"-frames:v", str(_chunk_count),
		"-c:v", "libx264",
		"-pix_fmt", "yuv420p",
		"-preset", "veryfast",
		"-crf", "20",
		"-an",
		"-y", _chunk_dir.path_join("chunk_%03d.mp4" % _chunk_index)
	]), false)
	_chunk_index += 1
	_chunk_count = 0
	if _pending_pid <= 0:
		_chunk_error = -1


func _wait_for_pending_chunk(temp_dir: String) -> void:
	if _pending_pid == -1:
		return
	while OS.is_process_running(_pending_pid):
		await get_tree().process_frame
	var code := OS.get_process_exit_code(_pending_pid)
	_pending_pid = -1
	if code != 0:
		_chunk_error = code
		return
	# The frames are safely muxed, so they are dead weight now. Only this chunk's
	# own range is dropped, which is what keeps the scratch folder small without
	# disturbing the frames the next chunk is in the middle of writing.
	for i in range(_pending_start, _pending_start + _pending_count):
		DirAccess.remove_absolute(temp_dir.path_join("frame_%06d.jpg" % i))

func _ffmpeg_path() -> String:
	var f := OS.get_environment("BOOMWHACKER_FFMPEG")
	return "ffmpeg" if f.is_empty() else f


func _apply_frame(t: float) -> void:
	_apply_intro(t)
	_apply_music_strip(t)
	_apply_overlay(t)


func _apply_intro(t: float) -> void:
	var card_alpha := 0.0
	var card_progress := 0.0
	# The card always clears out before the count-in takes over.
	var card_out := count_in_start - intro_card_fade
	if t >= intro_bg_fade and t < intro_bg_fade + 0.3:
		card_progress = (t - intro_bg_fade) / 0.3
		card_alpha = card_progress
		intro_card.visible = true
		intro_card.modulate = Color(1, 1, 1, card_alpha)
	elif t >= intro_bg_fade + 0.3 and t < card_out:
		card_progress = 1.0
		card_alpha = 1.0
		intro_card.visible = true
		intro_card.modulate = Color.WHITE
	elif t >= card_out and t < count_in_start:
		card_progress = 1.0
		card_alpha = 1.0 - (t - card_out) / intro_card_fade
		intro_card.visible = true
		intro_card.modulate = Color(1, 1, 1, card_alpha)
	else:
		card_progress = 0.0
		intro_card.visible = false

	var ease := _ease_out_back(clampf(card_progress, 0.0, 1.0))
	glass_panel.pivot_offset = glass_panel.size / 2.0
	glass_panel.scale = Vector2.ONE * (0.9 + 0.1 * ease)
	divider_line.pivot_offset = divider_line.size / 2.0
	divider_line.scale = Vector2(ease, 1.0)

	_apply_count_in(t)

	# The score has to be readable while the count-in runs, otherwise the numbers
	# count down over an empty screen. Fade it in with the first beat.
	var sheet_alpha := 0.0
	if t >= count_in_start:
		sheet_alpha = clampf((t - count_in_start) / count_in_fade, 0.0, 1.0)
	music_strip.modulate.a = sheet_alpha
	pinned_start.modulate.a = sheet_alpha
	pinned_divider.modulate.a = sheet_alpha


func _apply_count_in(t: float) -> void:
	var counting := t >= count_in_start and t < intro_total
	count_in_label.visible = counting
	if not counting:
		scroller_line.color.a = 0.7
		return
	var beat_u: float = clampf((t - count_in_start) / beat_seconds, 0.0, float(count_in_beats))
	var shown: int = 1 + int(floorf(beat_u))
	var u: float = beat_u - floorf(beat_u)
	count_in_label.text = str(shown)
	# Pop on the beat, then settle back, so each number reads as one click.
	var pop: float = lerpf(1.22, 1.0, clampf(u / 0.25, 0.0, 1.0))
	count_in_label.pivot_offset = count_in_label.size * 0.5
	count_in_label.scale = Vector2(pop, pop)
	# The last beat holds bright because the first note lands on top of it.
	var rest: float = 1.0 if shown >= count_in_beats else 0.5
	count_in_label.modulate = Color(1, 1, 1, lerpf(1.0, rest, u))
	scroller_line.color.a = lerpf(1.0, 0.7, u)


func _ease_out_back(x: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(x - 1.0, 3.0) + c1 * pow(x - 1.0, 2.0)


func _apply_music_strip(t: float) -> void:
	var scroll_t := t - intro_total
	var play_x: float = viewport_w * 0.5
	var px: float = _get_scroll_pixel(scroll_t)
	var shift: float = play_x - px
	if scroll_map.size() > 0:
		var last: Dictionary = scroll_map[scroll_map.size() - 1]
		var last_t: float = last.get("time", 0.0)
		if scroll_t > last_t:
			# Past the last note the score keeps going instead of stalling: it
			# reaches the closing double bar line exactly tail_beats later, then
			# carries on at that same rate while the video fades out.
			px = last.get("x", 0.0) + tail_rate * (scroll_t - last_t)
	if anchor_x.size() > 0 and t < intro_total:
		px = ScrollMath.entry_x(anchor_x[0], entry_rate, intro_total, count_in_start, t)
		shift = play_x - px
	var pin_x: float = maxf(shift, 0.0)
	pinned_start.offset_left = pin_x
	pinned_start.offset_right = pin_x + float(keep_start)
	pinned_divider.position.x = pin_x + float(keep_start) - 4.0
	var i := 0
	for rect in music_strip.get_children():
		if rect is Control:
			var base: float = tile_base_x[i] if i < tile_base_x.size() else 0.0
			rect.position.x = base + shift
			i += 1


func _apply_overlay(t: float) -> void:
	scroller_line.visible = t >= count_in_start and t < total_video_time
	if scroller_line.visible:
		var line_w := 6.0 * _layout_scale
		scroller_line.position = Vector2(viewport_w * 0.5 - line_w * 0.5, 0)
		scroller_line.size = Vector2(line_w, viewport_h)
		# Sit the count-in numbers on the playhead they are counting down to.
		var half := 220.0 * _layout_scale
		count_in_label.offset_left = -half
		count_in_label.offset_right = half
		count_in_label.offset_top = viewport_h * 0.28
		count_in_label.offset_bottom = viewport_h * 0.52
		count_in_label.add_theme_font_size_override("font_size", int(170.0 * _layout_scale))
		count_in_label.add_theme_constant_override("outline_size", int(22.0 * _layout_scale))
	var music_end := intro_total + total_duration
	var fade_black := 0.0
	if t > music_end:
		fade_black = clampf((t - music_end) / outro_duration, 0.0, 1.0)
	fade_to_black.color = Color(0, 0, 0, fade_black)

	var blur_u := 0.0
	if t >= intro_total - intro_blur_in:
		blur_u = clampf((t - (intro_total - intro_blur_in)) / intro_blur_in, 0.0, 1.0)
	background_blur.modulate.a = smoothstep(0.0, 1.0, blur_u)


func _save_click_wav() -> bool:
	if _click_stream == null:
		return false
	if not _click_path.is_empty() and FileAccess.file_exists(_click_path):
		return true
	# ffmpeg reads the click track from disk, so it has to exist as a real file.
	_click_path = output_folder.path_join("count_in_clicks.wav")
	var err := _click_stream.save_to_wav(_click_path)
	if err != OK:
		_click_path = ""
		return false
	return true


func _encode_video(chunk_dir: String) -> void:
	progress.emit(0.9)
	var output_path := output_folder.path_join(song_name.replace(" ", "_") + ".mp4")
	# The chunks are all encoded with identical settings, so the concat demuxer can
	# stitch them with a stream copy and never has to touch a pixel.
	var list_path := chunk_dir.path_join("chunks.txt")
	var f := FileAccess.open(list_path, FileAccess.WRITE)
	if f == null:
		_clear_dir(chunk_dir)
		_finish_export()
		done.emit("Could not write " + list_path)
		return
	for i in _chunk_index:
		f.store_line("file 'chunk_%03d.mp4'" % i)
	f.close()
	var args: PackedStringArray = [
		"-nostdin",
		"-loglevel", "error",
		"-f", "concat",
		"-safe", "0",
		"-i", list_path
	]
	if audio_path != "" and FileAccess.file_exists(audio_path):
		# adelay pads the audio with real silence samples. -itsoffset only shifts
		# timestamps, which makes the mp4 muxer write an edit list that players
		# skip, collapsing the intro delay back to zero.
		var delay_ms: int = int(round(intro_total * 1000.0))
		var click_ms: int = int(round(count_in_start * 1000.0))
		var has_clicks := _save_click_wav()
		if has_clicks:
			args.append_array([
				"-i", audio_path,
				"-i", _click_path,
				# normalize=0 keeps the mix at full level; amix would otherwise
				# halve the song just because the click track is a second input.
				"-filter_complex",
				"[1:a]adelay=%d:all=1[adelay];[2:a]adelay=%d:all=1[click];[adelay][click]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[mix]" % [delay_ms, click_ms],
				"-map", "0:v:0",
				"-map", "[mix]",
				"-c:v", "copy",
				"-c:a", "aac",
				"-b:a", "192k"
			])
		else:
			args.append_array([
				"-i", audio_path,
				"-filter_complex", "[1:a]adelay=%d:all=1[adelay]" % delay_ms,
				"-map", "0:v:0",
				"-map", "[adelay]",
				"-c:v", "copy",
				"-c:a", "aac",
				"-b:a", "192k"
			])
	else:
		args.append_array(["-c:v", "copy"])
	args.append_array([
		"-t", "%.3f" % total_video_time,
		"-movflags", "+faststart",
		"-y", output_path
	])
	var exit_code := OS.execute(_ffmpeg_path(), args, [], true)
	_clear_dir(chunk_dir)
	_clear_dir(output_folder.path_join("_temp_frames"))
	if not _click_path.is_empty():
		DirAccess.remove_absolute(_click_path)
	_finish_export()
	progress.emit(1.0)
	if exit_code == 0:
		done.emit("Exported to " + output_path)
	else:
		done.emit("FFmpeg failed with code " + str(exit_code))


func _clear_dir(dir: String) -> void:
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
