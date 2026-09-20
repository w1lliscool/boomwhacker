import sys
import struct
import wave
import math

try:
    import mido
except ImportError:
    print("ERROR: mido not installed")
    sys.exit(1)


MIDI_NOTE_FREQS = {}
for note in range(128):
    MIDI_NOTE_FREQS[note] = 440.0 * (2.0 ** ((note - 69) / 12.0))


def midi_to_wav(midi_path, wav_path, sample_rate=44100):
    mid = mido.MidiFile(midi_path)
    tempo = 500000
    events = []
    for track in mid.tracks:
        abs_time = 0
        for msg in track:
            abs_time += msg.time
            if msg.type == 'set_tempo':
                tempo = msg.tempo
            elif msg.type == 'note_on' and msg.velocity > 0:
                events.append(('on', abs_time, msg.note, msg.velocity))
            elif msg.type == 'note_off' or (msg.type == 'note_on' and msg.velocity == 0):
                events.append(('off', abs_time, msg.note, 0))

    tempo_map = []
    for track in mid.tracks:
        abs_ticks = 0
        for msg in track:
            abs_ticks += msg.time
            if msg.type == 'set_tempo':
                tempo_map.append((abs_ticks, msg.tempo))
    tempo_map.sort(key=lambda x: x[0])

    def ticks_to_seconds(ticks):
        seconds = 0.0
        prev_ticks = 0
        prev_tempo = 500000
        for t_ticks, t_tempo in tempo_map:
            if t_ticks >= ticks:
                break
            seconds += (t_ticks - prev_ticks) * prev_tempo / (mid.ticks_per_beat * 1000000.0)
            prev_ticks = t_ticks
            prev_tempo = t_tempo
        seconds += (ticks - prev_ticks) * prev_tempo / (mid.ticks_per_beat * 1000000.0)
        return seconds

    timed_events = []
    for etype, tick, note, vel in events:
        timed_events.append((ticks_to_seconds(tick), etype, note, vel))
    timed_events.sort(key=lambda x: x[0])

    if not timed_events:
        print("ERROR: No MIDI events found")
        sys.exit(1)

    last_time = max(t[0] for t in timed_events)
    total_samples = int(last_time * sample_rate) + sample_rate
    samples = [0.0] * total_samples

    active_notes = {}
    attack_time = 0.01
    decay_time = 0.05
    sustain_level = 0.7
    release_time = 0.05

    for t, etype, note, vel in timed_events:
        if etype == 'on':
            active_notes[note] = {'start': t, 'vel': vel / 127.0}
        elif etype == 'off' and note in active_notes:
            info = active_notes.pop(note)
            start_sec = info['start']
            end_sec = t
            velocity = info['vel']
            freq = MIDI_NOTE_FREQS.get(note, 440.0)
            start_s = int(start_sec * sample_rate)
            end_s = int(end_sec * sample_rate)
            release_s = int(release_time * sample_rate)
            for i in range(start_s, min(end_s + release_s, total_samples)):
                dt = (i / sample_rate) - start_sec
                note_dur = end_sec - start_sec
                env = 1.0
                if dt < attack_time:
                    env = dt / attack_time
                elif dt < attack_time + decay_time:
                    env = 1.0 - (1.0 - sustain_level) * ((dt - attack_time) / decay_time)
                elif dt < note_dur:
                    env = sustain_level
                else:
                    remaining = (dt - note_dur) / release_time
                    env = sustain_level * max(0.0, 1.0 - remaining)
                wave_val = (
                    0.5 * math.sin(2.0 * math.pi * freq * dt) +
                    0.2 * math.sin(2.0 * math.pi * freq * 2.0 * dt) +
                    0.1 * math.sin(2.0 * math.pi * freq * 3.0 * dt) +
                    0.05 * math.sin(2.0 * math.pi * freq * 4.0 * dt)
                )
                samples[i] += wave_val * env * velocity * 0.3

    max_val = max(abs(s) for s in samples) if samples else 1.0
    if max_val < 0.001:
        max_val = 1.0
    scale = 0.9 / max_val

    with wave.open(wav_path, 'w') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        for s in samples:
            val = int(s * scale * 32767)
            val = max(-32768, min(32767, val))
            wf.writeframes(struct.pack('<h', val))

    print(f"OK: {wav_path} ({last_time:.1f}s)")


if __name__ == "__main__":
    midi_path = sys.argv[1]
    wav_path = sys.argv[2]
    midi_to_wav(midi_path, wav_path)
