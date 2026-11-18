#!/usr/bin/env python3
"""Theme Marketplace catalog tools.

  theme-catalog.py validate FILE...       Check .bananatheme files the way bananaShell does.
  theme-catalog.py build SCHEMES_REPO     Regenerate Sources/PromptSupport/Catalog.

`build` reads a checkout of https://github.com/mbadolato/iTerm2-Color-Schemes
(only its windowsterminal/ folder and licenses.yml are needed) and keeps the
schemes whose licence permits redistribution. It adds the curated bundles below,
every community theme in Catalog/community/, and the like counts in
Catalog/likes.json (see Scripts/update-theme-likes.sh).
"""
import hashlib, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUPPORT = os.path.join(ROOT, "Sources", "PromptSupport")
CATALOG = os.path.join(SUPPORT, "Catalog")
PERMISSIVE = {"MIT", "MIT OR Apache-2.0", "Apache-2.0", "ISC", "CC0-1.0", "WTFPL",
              "Unlicense", "0BSD", "Zlib", "BSD-2-Clause", "BSD-3-Clause"}
KEYS = ["black", "red", "green", "yellow", "blue", "purple", "cyan", "white",
        "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue",
        "brightPurple", "brightCyan", "brightWhite"]
HEX = re.compile(r"^#[0-9A-Fa-f]{6}$")
LIBRARIES = {"oh-my-posh": "Oh My Posh", "starship": "Starship"}
DESIGNS = {"Classic", "Minimal", "Stacked", "Ribbon"}

# Curated themes: (id, name, summary, scheme, prompt, accent)
BUNDLES = [
    ("dracula-posh", "Dracula", "Dracula colors with the Dracula Oh My Posh prompt.", "Dracula",
     {"engine": "oh-my-posh", "file": "dracula.omp.json"}, "#BD93F9"),
    ("catppuccin-mocha-posh", "Catppuccin Mocha", "Soothing pastel dark theme with a matching prompt.", "Catppuccin Mocha",
     {"engine": "oh-my-posh", "file": "catppuccin_mocha.omp.json"}, "#CBA6F7"),
    ("catppuccin-latte-posh", "Catppuccin Latte", "Light Catppuccin flavor with a matching prompt.", "Catppuccin Latte",
     {"engine": "oh-my-posh", "file": "catppuccin_latte.omp.json"}, "#8839EF"),
    ("catppuccin-powerline", "Catppuccin Powerline", "Catppuccin Mocha with the Starship powerline preset.", "Catppuccin Mocha",
     {"engine": "starship", "file": "catppuccin-powerline.toml"}, "#F5C2E7"),
    ("tokyo-night-storm-posh", "Tokyo Night Storm", "Tokyo Night Storm colors and prompt.", "TokyoNight Storm",
     {"engine": "oh-my-posh", "file": "tokyonight_storm.omp.json"}, "#7AA2F7"),
    ("tokyo-night-starship", "Tokyo Night", "Tokyo Night colors with the Starship preset.", "TokyoNight Night",
     {"engine": "starship", "file": "tokyo-night.toml"}, "#7AA2F7"),
    ("gruvbox-rainbow", "Gruvbox Rainbow", "Retro Gruvbox colors with the rainbow Starship preset.", "Gruvbox Dark",
     {"engine": "starship", "file": "gruvbox-rainbow.toml"}, "#FE8019"),
    ("nord-nordtron", "Nord", "Arctic Nord colors with the Nordtron prompt.", "Nord",
     {"engine": "oh-my-posh", "file": "nordtron.omp.json"}, "#88C0D0"),
    ("rose-pine-ribbon", "Rosé Pine Ribbon", "Rosé Pine colors with the built-in Ribbon prompt.", "Rose Pine",
     {"engine": "builtin", "design": "Ribbon", "accent": "#EBBCBA", "identity": True}, "#EBBCBA"),
    ("kanagawa-minimal", "Kanagawa Minimal", "Kanagawa Wave colors with the built-in Minimal prompt.", "Kanagawa Wave",
     {"engine": "builtin", "design": "Minimal", "accent": "#7E9CD8", "identity": False}, "#7E9CD8"),
    ("everforest-stacked", "Everforest Stacked", "Everforest colors with the built-in Stacked prompt.", "Everforest Dark Med",
     {"engine": "builtin", "design": "Stacked", "accent": "#A7C080", "identity": True}, "#A7C080"),
    ("ayu-classic", "Ayu Classic", "Ayu colors with the built-in Classic prompt.", "Ayu",
     {"engine": "builtin", "design": "Classic", "accent": "#E6B450", "identity": True}, "#E6B450"),
]


def slug(name):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", name.lower())).strip("-")


def luminance(color):
    r, g, b = (int(color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def validate(theme):
    """Returns a list of problems; mirrors ThemeStore.validated in the app."""
    errors = []
    if theme.get("format") != 1:
        errors.append("format must be 1")
    if not theme.get("name"):
        errors.append("name is required")
    if not theme.get("id") or theme.get("id") != slug(theme["id"]):
        errors.append("id must be lowercase letters, digits and hyphens")
    scheme, prompt = theme.get("scheme"), theme.get("prompt")
    if not scheme and not prompt:
        errors.append("a theme needs a scheme, a prompt or both")
    if scheme:
        colors = scheme.get("ansi", [])
        required = colors + [scheme.get("background", ""), scheme.get("foreground", "")]
        optional = [c for c in (scheme.get("cursor"), scheme.get("selection")) if c is not None]
        if len(colors) != 16 or not all(HEX.match(c or "") for c in required + optional):
            errors.append("scheme needs 16 ansi colors plus background and foreground as #RRGGBB")
    if prompt:
        engine = prompt.get("engine")
        if engine == "builtin":
            if prompt.get("design", "Classic") not in DESIGNS:
                errors.append("builtin prompt design must be one of " + ", ".join(sorted(DESIGNS)))
        elif engine in LIBRARIES:
            if "content" in prompt:
                name = prompt.get("name", "")
                if os.path.splitext(name)[1] not in (".json", ".yaml", ".toml") or len(prompt["content"].encode()) >= 200_000:
                    errors.append("prompt content needs a .json, .yaml or .toml name and must stay under 200 KB")
            elif "/" in prompt.get("file", "/") or not os.path.exists(os.path.join(SUPPORT, LIBRARIES[engine], prompt["file"])):
                errors.append("prompt.file must name a prompt bundled with bananaShell, or use name + content")
        else:
            errors.append("prompt.engine must be builtin, oh-my-posh or starship")
    if theme.get("accent") and not HEX.match(theme["accent"]):
        errors.append("accent must be #RRGGBB")
    return errors


def warnings(theme):
    prompt = theme.get("prompt") or {}
    content = (prompt.get("content") or "").lower()
    if prompt.get("engine") == "starship" and ("[custom." in content or "command =" in content or "command=" in content):
        return ["Starship prompt runs custom commands"]
    if prompt.get("engine") == "oh-my-posh" and '"command"' in content:
        return ["Oh My Posh prompt runs commands"]
    return []


def parse_licenses(path):
    """Minimal parser for the flat two-level YAML in licenses.yml."""
    result, current = {}, None
    for line in open(path, encoding="utf-8"):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            key = line.rstrip().rstrip(":")
            if len(key) >= 2 and key[0] == key[-1] and key[0] in "'\"":
                key = key[1:-1].replace("''", "'")
            current = result.setdefault(key, {})
        elif current is not None and ":" in line:
            field, value = line.strip().split(":", 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            current[field] = value
    return result


def scheme_from(path):
    data = json.load(open(path, encoding="utf-8"))
    ansi = [data.get(k, "") for k in KEYS]
    bg, fg = data.get("background", ""), data.get("foreground", "")
    if not all(HEX.match(c or "") for c in ansi + [bg, fg]):
        return None
    cursor = data.get("cursorColor") or fg
    selection = data.get("selectionBackground") or ansi[8]
    return {"name": data["name"], "background": bg.upper(), "foreground": fg.upper(),
            "cursor": (cursor if HEX.match(cursor) else fg).upper(),
            "selection": (selection if HEX.match(selection) else ansi[8]).upper(),
            "ansi": [c.upper() for c in ansi]}


def entry_for(theme, rel, data, kind):
    prompt = theme.get("prompt")
    return {"id": theme["id"], "name": theme["name"], "kind": kind, "author": theme.get("author", ""),
            "license": theme.get("license", ""), "source": theme.get("source", ""), "tags": theme.get("tags", []),
            "appearance": theme.get("appearance"), "preview": theme.get("scheme"),
            "prompt": prompt["engine"] if prompt else None, "accent": theme.get("accent"),
            "summary": theme.get("summary"), "likes": 0, "file": rel, "sha256": hashlib.sha256(data).hexdigest()}


def write_theme(theme):
    os.makedirs(os.path.join(CATALOG, "themes"), exist_ok=True)
    rel = "themes/" + theme["id"] + ".bananatheme"
    data = (json.dumps(theme, indent=2, ensure_ascii=False) + "\n").encode()
    open(os.path.join(CATALOG, rel), "wb").write(data)
    return rel, data


def build(repo):
    licenses = parse_licenses(os.path.join(repo, "licenses.yml"))
    schemes, skipped = {}, 0
    folder = os.path.join(repo, "windowsterminal")
    for file in sorted(os.listdir(folder)):
        name = file[:-5]
        info = licenses.get(name, {})
        if info.get("license") not in PERMISSIVE:
            skipped += 1
            continue
        scheme = scheme_from(os.path.join(folder, file))
        if scheme:
            schemes[name] = (scheme, info)

    themes_dir = os.path.join(CATALOG, "themes")
    if os.path.isdir(themes_dir):
        for old in os.listdir(themes_dir):
            os.remove(os.path.join(themes_dir, old))

    bundles, plain = [], []
    for bid, title, summary, scheme_name, prompt, accent in BUNDLES:
        if scheme_name not in schemes:
            print("skipped bundle, its scheme is not redistributable:", bid, file=sys.stderr)
            continue
        scheme, info = schemes[scheme_name]
        appearance = "light" if luminance(scheme["background"]) > 0.5 else "dark"
        tags = [appearance, {"oh-my-posh": "oh-my-posh", "starship": "starship", "builtin": "built-in"}[prompt["engine"]]]
        theme = {"format": 1, "id": bid, "name": title, "author": "bananaShell", "summary": summary,
                 "license": info["license"], "source": info.get("source", ""), "tags": tags,
                 "appearance": appearance, "scheme": scheme, "prompt": prompt, "accent": accent}
        rel, data = write_theme(theme)
        bundles.append(entry_for(theme, rel, data, "bundle"))
    for name, (scheme, info) in sorted(schemes.items(), key=lambda kv: kv[0].lower()):
        appearance = "light" if luminance(scheme["background"]) > 0.5 else "dark"
        theme = {"format": 1, "id": slug(name), "name": name, "author": "", "summary": "Terminal color scheme.",
                 "license": info["license"], "source": info.get("source", ""), "tags": [appearance],
                 "appearance": appearance, "scheme": scheme}
        rel, data = write_theme(theme)
        plain.append(entry_for(theme, rel, data, "scheme"))

    community = []
    community_dir = os.path.join(CATALOG, "community")
    for file in sorted(os.listdir(community_dir)) if os.path.isdir(community_dir) else []:
        if not file.endswith(".bananatheme"):
            continue
        data = open(os.path.join(community_dir, file), "rb").read()
        theme = json.loads(data)
        problems = validate(theme) + warnings(theme)
        if problems:
            sys.exit(f"community/{file}: " + "; ".join(problems))
        community.append(entry_for(theme, "community/" + file, data, "bundle" if theme.get("prompt") else "scheme"))

    entries = bundles + community + plain
    ids = [e["id"] for e in entries]
    duplicates = {i for i in ids if ids.count(i) > 1}
    if duplicates:
        sys.exit("duplicate theme ids: " + ", ".join(sorted(duplicates)))
    likes_path = os.path.join(CATALOG, "likes.json")
    likes = json.load(open(likes_path)) if os.path.exists(likes_path) else {}
    for entry in entries:
        entry["likes"] = int(likes.get(entry["id"], 0))
    json.dump({"format": 1, "themes": entries}, open(os.path.join(CATALOG, "index.json"), "w", encoding="utf-8"),
              ensure_ascii=False, separators=(",", ":"))
    print(f"{len(bundles)} bundles, {len(community)} community, {len(plain)} schemes; "
          f"{skipped} schemes skipped for their licence", file=sys.stderr)


def main(args):
    if len(args) >= 2 and args[0] == "build":
        build(args[1])
    elif len(args) >= 2 and args[0] == "validate":
        failed = False
        for path in args[1:]:
            try:
                theme = json.load(open(path, encoding="utf-8"))
            except (OSError, ValueError) as error:
                print(f"{path}: {error}"); failed = True; continue
            problems = validate(theme)
            for problem in problems:
                print(f"{path}: {problem}")
            for warning in warnings(theme):
                print(f"{path}: not accepted in the catalog: {warning}")
            failed = failed or bool(problems or warnings(theme))
            if not problems:
                print(f"{path}: ok")
        sys.exit(1 if failed else 0)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
