"""Build companion backgrounds from bundled themes and their rendered samples."""
from collections import Counter
import colorsys
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1] / "Sources/PromptSupport"
samples = json.loads((root / "preview-samples.json").read_text())
backgrounds = {}
interface_accents = {}
bases = {"tokyo-night.toml": "#1A1B26", "gruvbox-rainbow.toml": "#282828",
         "catppuccin-powerline.toml": "#1E1E2E"}
ansi = ("000000 AA0000 00AA00 AA5500 0000AA AA00AA 00AAAA AAAAAA "
        "555555 FF5555 55FF55 FFFF55 5555FF FF55FF 55FFFF FFFFFF").split()
for name, sample in samples.items():
    background = bases.get(name)
    if name.endswith(".json"):
        config = json.loads((root / "Oh My Posh" / name).read_text())
        declared = config.get("terminal_background", "")
        seen = set()
        while declared.startswith("p:") and declared not in seen:
            seen.add(declared)
            declared = config.get("palette", {}).get(declared[2:], "")
        if re.fullmatch(r"#[0-9a-fA-F]{6}", declared):
            background = declared
    accents = Counter()
    for sgr in re.findall(r"\x1b\[([\d;]*)m", sample):
        codes = iter(int(n or 0) for n in sgr.split(";"))
        for code in codes:
            rgb = None
            if code in (38, 48):
                mode = next(codes, None)
                if mode == 2:
                    rgb = tuple(next(codes, 0) for _ in range(3))
                elif mode == 5:
                    idx = next(codes, 0)
                    if idx < 16:
                        rgb = bytes.fromhex(ansi[idx])
                    elif idx < 232:
                        cube = [0, 95, 135, 175, 215, 255]
                        rgb = tuple(cube[(idx-16)//div % 6] for div in (36, 6, 1))
            elif 30 <= code <= 37 or 90 <= code <= 97:
                rgb = bytes.fromhex(ansi[code-30 if code < 90 else code-82])
            if rgb and max(rgb)-min(rgb) > 24:
                accents[tuple(rgb)] += 1
    rgb = accents.most_common(1)[0][0] if accents else (90, 103, 123)
    h, l, s = colorsys.rgb_to_hls(*(c/255 for c in rgb))
    # Keep the prompt hue, but lift dark ANSI colors for use on the app's dark chrome.
    interface_accents[name] = "#" + "".join(f"{round(c*255):02X}" for c in
        colorsys.hls_to_rgb(h, max(.65, min(.80, l)), min(.80, s)))
    if not background:
        background = "#" + "".join(f"{round(c*255):02X}" for c in colorsys.hls_to_rgb(h, .135, min(.43, s)))
    backgrounds[name] = background.upper()
(root / "theme-backgrounds.json").write_text(json.dumps(backgrounds, indent=2, sort_keys=True) + "\n")
(root / "theme-accents.json").write_text(json.dumps(interface_accents, indent=2, sort_keys=True) + "\n")
