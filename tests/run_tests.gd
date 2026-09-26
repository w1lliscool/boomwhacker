extends SceneTree

# Headless checks for the parts of the video that are pure arithmetic. Run with:
#   godot --headless --script tests/run_tests.gd
#
# None of this touches a window, the renderer, or a display server, so it is safe
# to run unattended. The bugs this covers (a per-part beat counter that never
# reset, an intro that scrolled the wrong way, an outro that froze on a flat
# scroll-map segment) were all geometry mistakes that this catches in
# milliseconds instead of after a three minute preview.

const ScrollMath = preload("res://scripts/scroll_math.gd")
const Parser = preload("res://scripts/musicxml_parser.gd")

var passed := 0
var failed := 0
var tmp_dir := ""


func _initialize() -> void:
	tmp_dir = OS.get_user_data_dir().path_join("_boomwhacker_tests")
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	_run()
	print("")
	if failed == 0:
		print("PASS  %d checks" % passed)
	else:
		printerr("FAIL  %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _run() -> void:
	_test_count_in_schedule()
	_test_count_in_lands_on_downbeat()
	_test_entry_moves_left_only()
	_test_tail_rate_reaches_the_bar()
	_test_tail_survives_flat_scroll_map()
	_test_db_to_amp()
	_test_parser_beats_reset_per_part()
	_test_parser_single_part()
	_cleanup()


func _ok(cond: bool, label: String) -> void:
	if cond:
		passed += 1
		print("  ok   " + label)
	else:
		failed += 1
		printerr("  FAIL " + label)


func _near(a: float, b: float, tol: float = 0.0005) -> bool:
	return absf(a - b) <= tol


# --- ScrollMath ------------------------------------------------------------

func _test_count_in_schedule() -> void:
	var s := ScrollMath.count_in_schedule(45.0, 4, 0.5, 0.8, 6.8)
	# 45 BPM -> 1.3333s per beat, four beats is 5.3333s, and the card needs
	# 0.5 + 0.3 + 1.4 + 0.8 = 3.0s, so the intro stretches to 8.3333s.
	_ok(_near(s["beat_seconds"], 1.33333, 0.001), "count-in beat length at 45 BPM")
	_ok(_near(s["count_in_time"], 5.33333, 0.001), "count-in lasts four beats")
	_ok(_near(s["intro_total"], 8.33333, 0.001), "intro stretches to fit the count-in")
	_ok(_near(s["count_in_start"], 3.0, 0.001), "count-in starts once the card is gone")
	# The count-in must end exactly where the music starts, or the first note is
	# early or late.
	_ok(_near(s["count_in_start"] + s["count_in_time"], s["intro_total"]), "count-in ends on the music")
	# A fast tempo should not shrink the intro below its floor.
	var fast := ScrollMath.count_in_schedule(200.0, 4, 0.5, 0.8, 6.8)
	_ok(_near(fast["intro_total"], 6.8), "fast tempo respects the minimum intro")
	# A zero tempo must not divide by zero.
	var zero := ScrollMath.count_in_schedule(0.0, 4, 0.5, 0.8, 6.8)
	_ok(zero["beat_seconds"] > 0.0, "zero tempo falls back instead of dividing by zero")


func _test_count_in_lands_on_downbeat() -> void:
	var s := ScrollMath.count_in_schedule(45.0, 4, 0.5, 0.8, 6.8)
	var first_x := 1014.71
	var rate := 258.6
	# The whole point of the backwards extrapolation: the first note sits on the
	# playhead exactly when the music starts.
	_ok(_near(ScrollMath.entry_x(first_x, rate, s["intro_total"], s["count_in_start"], s["intro_total"]), first_x),
		"first note reaches the playhead at the music start")


func _test_entry_moves_left_only() -> void:
	var intro := 8.33333
	var start := 3.0
	var first_x := 1014.71
	var rate := 258.6
	var t := 0.0
	var prev := INF
	var backwards := false
	var moved := false
	# Sample the whole intro. Before the count-in the score should be parked
	# (held at the entry x), then travel strictly left, never reversing.
	while t <= intro:
		var x := ScrollMath.entry_x(first_x, rate, intro, start, t)
		if x < first_x:
			moved = true
		if x > prev:
			backwards = true
		prev = x
		t += 0.05
	_ok(not backwards, "score never scrolls backwards during the intro")
	_ok(moved, "score actually moves during the intro")
	# Before the count-in begins it holds still, it does not run early.
	_ok(_near(ScrollMath.entry_x(first_x, rate, intro, start, 0.0), ScrollMath.entry_x(first_x, rate, intro, start, 2.9)),
		"score holds position until the count-in starts")
	# It comes in from the right, i.e. the entry x is greater than the first note.
	_ok(ScrollMath.entry_x(first_x, rate, intro, start, 0.0) > first_x, "entry starts to the right of the first note")


func _test_tail_rate_reaches_the_bar() -> void:
	# Real numbers from music_for_a_while: the last note sits at 66447.2 and the
	# sheet is 67124.8 wide, so the tail has 677.6 units left to cross in four
	# beats of 1.3333s.
	var rate := ScrollMath.tail_rate_for(66447.2, 67124.8, 4, 1.33333)
	_ok(rate > 0.0, "tail rate is positive")
	_ok(_near(ScrollMath.tail_x_at(66447.2, rate, 202.6667, 202.6667 + 4.0 * 1.33333), 67124.8, 0.01),
		"tail reaches the closing bar line after four beats")
	# A zero-length tail window must not divide by zero.
	_ok(ScrollMath.tail_rate_for(100.0, 200.0, 4, 0.0) > 0.0, "zero-length tail window is guarded")
	# Never scroll backwards, even if the end bar is behind the last note.
	_ok(_near(ScrollMath.tail_rate_for(200.0, 100.0, 4, 1.0), 0.0), "tail never runs backwards")


func _test_tail_survives_flat_scroll_map() -> void:
	# The original bug: the last two scroll points were identical (a held
	# semibreve), so the rate derived from the map was zero and the outro froze.
	var last_x := 66447.2
	var end_bar := 67124.8
	var flat_segment := (last_x - last_x) / (202.6667 - 197.3333)
	_ok(_near(flat_segment, 0.0), "reproduces the flat final scroll segment")
	var rate := ScrollMath.tail_rate_for(last_x, end_bar, 4, 1.33333)
	_ok(rate > flat_segment, "tail rate ignores the flat segment and still moves")


func _test_db_to_amp() -> void:
	_ok(_near(ScrollMath.db_to_amp(0.0), 1.0, 0.0001), "0 dB is unity")
	# -22 dBFS was chosen to sit just under the song's -17.5 dBFS peak.
	_ok(_near(ScrollMath.db_to_amp(-22.0), 0.07943, 0.0001), "-22 dB maps to the click accent level")
	_ok(ScrollMath.db_to_amp(-22.0) < 1.0, "negative dB attenuates")


# --- MusicXMLParser --------------------------------------------------------

const TWO_PART_XML := """<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list>
    <score-part id="P1"><part-name>Flute</part-name></score-part>
    <score-part id="P2"><part-name>Trumpet</part-name></score-part>
  </part-list>
  <part id="P1">
    <measure number="1">
      <attributes><divisions>4</divisions></attributes>
      <direction><sound tempo="120"/></direction>
      <note><pitch><step>C</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>
    </measure>
  </part>
  <part id="P2">
    <measure number="1">
      <attributes><divisions>4</divisions></attributes>
      <note><pitch><step>D</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>
    </measure>
  </part>
</score-partwise>
"""


func _write_temp(name: String, contents: String) -> String:
	var path := tmp_dir.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(contents)
	f.close()
	return path


func _test_parser_beats_reset_per_part() -> void:
	# Two one-measure parts at 120 BPM, each holding a whole note. One 4/4
	# measure at 120 BPM is 2 seconds. If the beat counter carried over between
	# parts, part two would start at beat 4 instead of beat 0 and the piece would
	# report 4 seconds. This is the regression that made the original song score
	# 354 seconds instead of 208.
	var path := _write_temp("two_parts.musicxml", TWO_PART_XML)
	var parser = Parser.new()
	parser.parse(path)
	_ok(_near(parser.get_total_time(), 2.0, 0.01), "two parts of one measure total two seconds, not four")
	_ok(_near(float(parser.get_tempo()), 120.0, 0.01), "tempo is picked up from the score")


func _test_parser_single_part() -> void:
	var one_part := TWO_PART_XML.replace("""    <score-part id="P2"><part-name>Trumpet</part-name></score-part>
""", "").replace("""  <part id="P2">
    <measure number="1">
      <attributes><divisions>4</divisions></attributes>
      <note><pitch><step>D</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>
    </measure>
  </part>
""", "")
	var path := _write_temp("one_part.musicxml", one_part)
	var parser = Parser.new()
	parser.parse(path)
	_ok(_near(parser.get_total_time(), 2.0, 0.01), "a single part of one measure totals two seconds")


func _cleanup() -> void:
	if not tmp_dir.is_empty() and DirAccess.dir_exists_absolute(tmp_dir):
		_remove_tree(tmp_dir)


func _remove_tree(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var e := d.get_next()
	while e != "":
		var full := path.path_join(e)
		if d.current_is_dir():
			_remove_tree(full)
		else:
			DirAccess.remove_absolute(full)
		e = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)
