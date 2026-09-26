extends RefCounted
class_name ScrollMath

# Pure timing and position maths for the video, deliberately free of any scene or
# node dependency. Everything here used to live inline in video_renderer.gd, where
# the only way to check it was to launch the editor and watch a preview. Keeping
# it separate lets the geometry be tested headlessly in milliseconds.

# Lays out the intro so the count-in always fits between the card fading out and
# the music starting, even at a slow tempo.
static func count_in_schedule(tempo: float, beats: int, intro_bg_fade: float, intro_card_fade: float, min_intro: float) -> Dictionary:
	var safe_tempo: float = maxf(tempo, 1.0)
	var beat_seconds: float = 60.0 / safe_tempo
	var count_in_time: float = float(beats) * beat_seconds
	# Card start, then the card's own length, then the count-in.
	var needed: float = intro_bg_fade + 0.3 + 1.4 + intro_card_fade + count_in_time
	var intro_total: float = maxf(min_intro, needed)
	return {
		"tempo": safe_tempo,
		"beat_seconds": beat_seconds,
		"count_in_time": count_in_time,
		"intro_total": intro_total,
		"count_in_start": intro_total - count_in_time,
	}


# Score x during the count-in. Runs the song's own opening speed backwards, so the
# sheet enters from the right travelling left and the first note lands on the
# playhead. It holds at the entry position until the count-in begins, otherwise
# the earlier part would run forwards and appear to scroll backwards.
static func entry_x(first_x: float, entry_rate: float, intro_total: float, count_in_start: float, t: float) -> float:
	var hold: float = maxf(t, count_in_start)
	var window: float = maxf(intro_total - count_in_start, 0.0)
	var pre: float = clampf(intro_total - hold, 0.0, window)
	return first_x - entry_rate * pre


# The last scroll-map entries can be flat (a held semibreve), so extrapolating
# from them yields a zero rate and the outro freezes. This derives the closing
# rate from the distance that is actually left instead.
static func tail_rate_for(last_x: float, end_x: float, tail_beats: int, beat_seconds: float) -> float:
	var span: float = maxf(float(tail_beats) * beat_seconds, 0.000001)
	return maxf((end_x - last_x) / span, 0.0)


static func tail_x_at(last_x: float, rate: float, last_t: float, scroll_t: float) -> float:
	return last_x + rate * (scroll_t - last_t)


static func db_to_amp(db: float) -> float:
	return pow(10.0, db / 20.0)
