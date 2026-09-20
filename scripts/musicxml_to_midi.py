import sys
import xml.etree.ElementTree as ET

try:
    import mido
except ImportError:
    print("ERROR: mido not installed")
    sys.exit(1)


def musicxml_to_midi(xml_path, midi_path):
    tree = ET.parse(xml_path)
    root = tree.getroot()
    ns = ''
    for n in ['{http://www.musicxml.org/ns/musicxml/4.0}', '{http://www.musicxml.org/ns/musicxml/3.1}', '{http://www.musicxml.org/ns/musicxml/1.0}']:
        if root.find(n + 'note') is not None:
            ns = n
            break

    def t(tag):
        return ns + tag if ns else tag

    tempo = 120.0
    divisions = 4
    key_fifths = 0
    time_beats = 4
    time_beat_type = 4

    for sound in root.iter(t('sound')):
        tp = sound.get('tempo')
        if tp:
            tempo = float(tp)
    for attr in root.iter(t('attributes')):
        d = attr.find(t('divisions'))
        if d is not None and d.text:
            divisions = int(d.text)
        kf = attr.find(t('key'))
        if kf is not None:
            fifths = kf.find(t('fifths'))
            if fifths is not None and fifths.text:
                key_fifths = int(fifths.text)
        tm = attr.find(t('time'))
        if tm is not None:
            beats_el = tm.find(t('beats'))
            bt_el = tm.find(t('beat-type'))
            if beats_el is not None and beats_el.text:
                time_beats = int(beats_el.text)
            if bt_el is not None and bt_el.text:
                time_beat_type = int(bt_el.text)

    mid = mido.MidiFile(ticks_per_beat=480)
    track = mido.MidiTrack()
    mid.tracks.append(track)
    track.append(mido.MetaMessage('set_tempo', tempo=mido.bpm2tempo(tempo), time=0))
    fifths_to_key = {
        -7: 'Cb', -6: 'Gb', -5: 'Db', -4: 'Ab', -3: 'Eb', -2: 'Bb', -1: 'F',
        0: 'C', 1: 'G', 2: 'D', 3: 'A', 4: 'E', 5: 'B', 6: 'F#', 7: 'C#'
    }
    track.append(mido.MetaMessage('key_signature', key=fifths_to_key.get(key_fifths, 'C'), time=0))
    track.append(mido.MetaMessage('time_signature', numerator=time_beats, denominator=time_beat_type, time=0))

    pitch_names = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}

    def note_to_midi(pitch_str):
        if not pitch_str:
            return 60
        letter = pitch_str[0].upper()
        octave = int(pitch_str[-1]) if pitch_str[-1].isdigit() else 4
        alter = 0
        for ch in pitch_str[1:-1]:
            if ch == '#':
                alter += 1
            elif ch == '-':
                alter -= 1
        return 12 * (octave + 1) + pitch_names.get(letter, 0) + alter

    all_notes = []
    current_beat = 0.0
    measure_beat = 0.0

    for part in root.iter(t('part')):
        current_beat = 0.0
        measure_beat = 0.0
        for measure in part.iter(t('measure')):
            measure_beat = 0.0
            for note in measure.iter(t('note')):
                is_rest = note.find(t('rest')) is not None
                is_chord = note.find(t('chord')) is not None
                is_grace = note.find(t('grace')) is not None
                if is_grace:
                    continue
                pitch_el = note.find(t('pitch'))
                dur_el = note.find(t('duration'))
                dur = int(dur_el.text) if dur_el is not None and dur_el.text else 0
                pitch_str = ''
                if pitch_el is not None:
                    step = pitch_el.find(t('step'))
                    octave_el = pitch_el.find(t('octave'))
                    alter_el = pitch_el.find(t('alter'))
                    if step is not None and step.text:
                        pitch_str = step.text
                        if alter_el is not None and alter_el.text:
                            alt = int(float(alter_el.text))
                            pitch_str += '#' * max(0, alt) + '-' * max(0, -alt)
                        if octave_el is not None and octave_el.text:
                            pitch_str += octave_el.text
                if not is_rest and dur > 0 and pitch_str:
                    midi_note = note_to_midi(pitch_str)
                    all_notes.append({
                        'time_beats': current_beat + measure_beat,
                        'duration_beats': dur / divisions,
                        'note': midi_note,
                        'velocity': 80,
                    })
                if not is_chord:
                    measure_beat += dur / divisions
            current_beat += measure_beat

    all_notes.sort(key=lambda n: n['time_beats'])
    ticks_per_beat = mid.ticks_per_beat

    events = []
    for n in all_notes:
        start_tick = int(n['time_beats'] * ticks_per_beat)
        end_tick = int((n['time_beats'] + n['duration_beats']) * ticks_per_beat)
        events.append((start_tick, 'note_on', n['note'], n['velocity']))
        events.append((end_tick, 'note_off', n['note'], 0))
    events.sort(key=lambda e: (e[0], 0 if e[1] == 'note_on' else 1))

    prev_tick = 0
    for tick, msg_type, note, vel in events:
        delta = tick - prev_tick
        track.append(mido.Message(msg_type, note=note, velocity=vel, time=delta))
        prev_tick = tick

    track.append(mido.MetaMessage('end_of_track', time=0))
    mid.save(midi_path)
    print(f"OK: {midi_path} ({len(all_notes)} notes, {tempo} bpm)")


if __name__ == "__main__":
    xml_path = sys.argv[1]
    midi_path = sys.argv[2]
    musicxml_to_midi(xml_path, midi_path)
