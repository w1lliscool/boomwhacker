import re, os, sys, json
import xml.etree.ElementTree as ET
from resvg_py import svg_to_bytes
from PIL import Image
import io


def trim_svg(svg_path, output_path):
    with open(svg_path, 'r', encoding='utf-8') as f:
        svg = f.read()
    min_x, min_y, max_x, max_y = float('inf'), float('inf'), float('-inf'), float('-inf')
    for pts in re.findall(r'points="([^"]+)"', svg):
        nums = [float(n) for n in pts.strip().replace(',', ' ').split()]
        for i in range(0, len(nums) - 1, 2):
            min_x, max_x = min(min_x, nums[i]), max(max_x, nums[i])
            min_y, max_y = min(min_y, nums[i+1]), max(max_y, nums[i+1])
    for d in re.findall(r'<path[^>]*d="([^"]+)"', svg):
        coords = extract_coords(d)
        for i in range(0, len(coords) - 1, 2):
            min_x, max_x = min(min_x, coords[i]), max(max_x, coords[i])
            min_y, max_y = min(min_y, coords[i+1]), max(max_y, coords[i+1])
    pad = 10
    min_x = max(min_x - pad, 0)
    min_y = max(min_y - pad, 0)
    max_x += pad
    max_y += pad
    content_w = max_x - min_x
    content_h = max_y - min_y
    svg = re.sub(r'viewBox="[^"]+"', f'viewBox="{min_x} {min_y} {content_w} {content_h}"', svg, count=1)
    svg = re.sub(r'width="[^"]+"', f'width="{content_w}"', svg, count=1)
    svg = re.sub(r'height="[^"]+"', f'height="{content_h}"', svg, count=1)
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(svg)
    return {"x": min_x, "y": min_y, "width": content_w, "height": content_h}


def extract_coords(d):
    result = []
    d = re.sub(r'[MmCcLlZzHhVvSsQqTtAa]', ' ', d)
    for token in d.replace(',', ' ').split():
        try:
            result.append(float(token))
        except ValueError:
            pass
    return result


def extract_note_positions(svg_path):
    with open(svg_path, 'r', encoding='utf-8') as f:
        svg = f.read()
    notes = []
    for m in re.finditer(r'class="Note"[^>]*transform="matrix\(([^)]+)\)"', svg):
        parts = m.group(1).split(',')
        if len(parts) >= 5:
            sx = float(parts[0].strip())
            x = float(parts[4].strip())
            y = float(parts[5].strip()) if len(parts) > 5 else 0
            if sx < 0.85:
                continue
            notes.append({"x": x, "y": y})
    notes.sort(key=lambda n: n["x"])
    return notes


def parse_musicxml_notes(xml_path):
    tree = ET.parse(xml_path)
    root = tree.getroot()
    ns = ''
    tag_test = root.find('note')
    if tag_test is None:
        for n in ['{http://www.musicxml.org/ns/musicxml/4.0}', '{http://www.musicxml.org/ns/musicxml/3.1}', '{http://www.musicxml.org/ns/musicxml/1.0}']:
            if root.find(n + 'note') is not None:
                ns = n
                break

    def t(tag):
        return ns + tag if ns else tag

    tempo = 120.0
    divisions = 4
    for sound in root.iter(t('sound')):
        tp = sound.get('tempo')
        if tp:
            tempo = float(tp)
    for attr in root.iter(t('attributes')):
        d = attr.find(t('divisions'))
        if d is not None and d.text:
            divisions = int(d.text)

    all_notes = []
    bar_times = []
    measure_num = 0
    for part in root.iter(t('part')):
        current_beat = 0.0
        measure_num = 0
        for measure in part.iter(t('measure')):
            measure_num += 1
            bar_times.append({
                "bar": measure_num,
                "time_sec": current_beat * 60.0 / tempo,
            })
            cursor_div = 0
            last_chord_div = {}
            measure_beats = 4.0
            for attr in measure.iter(t('attributes')):
                time_el = attr.find(t('time'))
                if time_el is not None:
                    beats_el = time_el.find(t('beats'))
                    if beats_el is not None and beats_el.text:
                        measure_beats = float(beats_el.text)
            for child in measure:
                tag = child.tag.replace(ns, '') if ns else child.tag
                if child.tag != t('backup') and child.tag != t('forward') and child.tag != t('note'):
                    continue
                if child.tag == t('backup'):
                    dur_el = child.find(t('duration'))
                    dur = int(dur_el.text) if dur_el is not None and dur_el.text else 0
                    cursor_div -= dur
                    continue
                if child.tag == t('forward'):
                    dur_el = child.find(t('duration'))
                    dur = int(dur_el.text) if dur_el is not None and dur_el.text else 0
                    cursor_div += dur
                    continue
                note = child
                is_rest = note.find(t('rest')) is not None
                is_chord = note.find(t('chord')) is not None
                is_grace = note.find(t('grace')) is not None
                dur_el = note.find(t('duration'))
                dur = int(dur_el.text) if dur_el is not None and dur_el.text else 0
                if is_grace:
                    continue
                voice_el = note.find(t('voice'))
                voice = voice_el.text.strip() if voice_el is not None and voice_el.text else '1'
                if is_rest:
                    cursor_div += dur
                    continue
                if is_chord:
                    start_div = last_chord_div.get(voice, cursor_div)
                    if dur > 0:
                        all_notes.append({
                            "time_beats": current_beat + start_div / divisions,
                            "duration_beats": dur / divisions,
                        })
                    continue
                start_div = cursor_div
                last_chord_div[voice] = cursor_div
                cursor_div += dur
                if dur > 0:
                    all_notes.append({
                        "time_beats": current_beat + start_div / divisions,
                        "duration_beats": dur / divisions,
                    })
            current_beat += measure_beats

    all_notes.sort(key=lambda n: n["time_beats"])
    for note in all_notes:
        note["time_sec"] = note["time_beats"] * 60.0 / tempo
    total_time = 0.0
    if all_notes:
        last = all_notes[-1]
        total_time = (last["time_beats"] + last["duration_beats"]) * 60.0 / tempo
    return all_notes, tempo, total_time


def build_scroll_map(svg_notes, xml_notes, total_time):
    scroll_map = []
    if not svg_notes or not xml_notes:
        return scroll_map, total_time
    n_svg = len(svg_notes)
    n_xml = len(xml_notes)
    first_x = svg_notes[0]["x"]
    scroll_map.append({"time": 0.0, "x": first_x})
    for i in range(1, n_xml):
        if n_svg == n_xml:
            svg_idx = i
        else:
            svg_idx = int(round(float(i) * (n_svg - 1) / (n_xml - 1)))
        svg_idx = min(svg_idx, n_svg - 1)
        scroll_map.append({
            "time": xml_notes[i]["time_sec"],
            "x": svg_notes[svg_idx]["x"]
        })
    scroll_map.sort(key=lambda e: e["time"])
    last_x = svg_notes[n_svg - 1]["x"]
    scroll_map.append({"time": total_time, "x": last_x})
    return scroll_map, total_time


def render_svg_to_png(svg_path, output_png, scale=1.0):
    with open(svg_path, 'r', encoding='utf-8') as f:
        svg_str = f.read()
    vb = re.search(r'viewBox="([^"]+)"', svg_str)
    if not vb:
        return False, 0, 0
    parts = vb.group(1).split()
    vb_w, vb_h = float(parts[2]), float(parts[3])
    target_w = int(vb_w * scale)
    target_h = int(vb_h * scale)
    svg_str = re.sub(r'width="[^"]+"', f'width="{target_w}"', svg_str, count=1)
    svg_str = re.sub(r'height="[^"]+"', f'height="{target_h}"', svg_str, count=1)
    try:
        png_bytes = svg_to_bytes(svg_str)
        img = Image.open(io.BytesIO(png_bytes))
        img.save(output_png)
        return True, img.size[0], img.size[1]
    except Exception as e:
        print(f"resvg error: {e}")
        return False, 0, 0


if __name__ == "__main__":
    svg_path = sys.argv[1]
    output_dir = sys.argv[2]
    xml_path = sys.argv[3] if len(sys.argv) > 3 else ""

    trimmed_path = os.path.join(output_dir, "trimmed.svg")
    png_path = os.path.join(output_dir, "sheet.png")

    MAX_TEX_WIDTH = 16384

    trim_data = trim_svg(svg_path, trimmed_path)
    svg_notes = extract_note_positions(trimmed_path)
    ok, pw, ph = render_svg_to_png(trimmed_path, png_path, scale=0.5)

    # Split PNG into tiles if wider than Godot's max texture width
    tile_paths = []
    tile_widths = []
    if pw > MAX_TEX_WIDTH and ok:
        img = Image.open(png_path)
        num_tiles = (pw + MAX_TEX_WIDTH - 1) // MAX_TEX_WIDTH
        for i in range(num_tiles):
            x_start = i * MAX_TEX_WIDTH
            x_end = min((i + 1) * MAX_TEX_WIDTH, pw)
            tile = img.crop((x_start, 0, x_end, ph))
            tile_path = os.path.join(output_dir, f"sheet_tile_{i}.png")
            tile.save(tile_path)
            tile_paths.append(tile_path)
            tile_widths.append(x_end - x_start)
        os.remove(png_path)
        png_path = tile_paths[0] if tile_paths else png_path
    else:
        tile_paths = [png_path]
        tile_widths = [pw] if ok else [0]

    xml_notes = []
    total_time = 0.0
    tempo = 120.0
    if xml_path and os.path.exists(xml_path):
        xml_notes, tempo, total_time = parse_musicxml_notes(xml_path)

    scroll_map, total_time = build_scroll_map(svg_notes, xml_notes, total_time)

    result = {
        "trim": trim_data,
        "notes": svg_notes,
        "png": png_path,
        "trimmed_svg": trimmed_path,
        "png_width": pw,
        "png_height": ph,
        "tile_paths": tile_paths,
        "tile_widths": tile_widths,
        "scroll_map": scroll_map,
        "tempo": tempo,
        "total_time": total_time,
    }
    result_path = os.path.join(output_dir, "result.json")
    with open(result_path, 'w') as f:
        json.dump(result, f)
    print(f"OK: {len(svg_notes)} svg notes, {len(xml_notes)} xml notes, {len(scroll_map)} scroll points, tempo={tempo}, total={total_time:.1f}s")
