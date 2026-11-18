# Themes

A bananaShell theme is a `.bananatheme` file: JSON describing any of terminal colors, a prompt, an interface accent and a font. A color scheme on its own is a theme with only `scheme`.

```json
{
  "format": 1,
  "id": "my-theme",
  "name": "My Theme",
  "author": "Your Name",
  "summary": "One sentence about it.",
  "license": "MIT",
  "source": "https://example.com/where-the-colors-come-from",
  "tags": ["dark", "pastel"],
  "appearance": "dark",
  "scheme": {
    "name": "My Theme",
    "background": "#1E1E2E",
    "foreground": "#CDD6F4",
    "cursor": "#F5E0DC",
    "selection": "#585B70",
    "ansi": ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
             "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"]
  },
  "prompt": { "engine": "builtin", "design": "Ribbon", "accent": "#CBA6F7", "identity": true },
  "accent": "#CBA6F7",
  "font": { "name": "JetBrainsMonoNLNFM-Regular" }
}
```

| Field | Meaning |
| --- | --- |
| `id` | Lowercase letters, digits and hyphens; unique in the catalog. |
| `scheme.ansi` | The 16 ANSI colors in order: black, red, green, yellow, blue, magenta, cyan, white, then the bright versions. All colors are `#RRGGBB`. |
| `prompt` | `{"engine": "builtin", "design": "Classic" \| "Minimal" \| "Stacked" \| "Ribbon", "accent", "identity"}`; or `{"engine": "oh-my-posh" \| "starship", "file": "<bundled file name>"}` for a prompt that ships with bananaShell; or `{"engine": …, "name": "<file name>.json/.toml/.yaml", "content": "<the whole prompt file>"}` for your own. |
| `accent` | Tabs, buttons and selections, while the theme's prompt is in use. |
| `font` | PostScript name of a monospaced font; skipped if it is not installed. |

Prompts in a theme must not run shell commands: the app warns before installing a theme whose Starship prompt has `custom` modules or whose Oh My Posh prompt has `command` segments, and the catalog does not accept them.

## Sharing

- The **Export** button (square with an upward arrow) in Theme Marketplace saves your current colors, prompt, accent and font as a `.bananatheme` file. Double-clicking that file opens it in bananaShell.
- `bananashell://theme?id=<catalog id>` opens a catalog theme; `bananashell://theme?url=https://…/file.bananatheme` opens a theme hosted anywhere over HTTPS. **Copy Link** in a theme's details copies the first form.
- Themes from files and links are shown for review before anything is installed.

## Submitting to the catalog

1. Export your setup from Theme Marketplace, then attach the saved file to a [theme submission issue](https://github.com/howon-kim/bananaShell/issues/new?template=theme.yml).
2. Or open a pull request that adds `Sources/PromptSupport/Catalog/community/<id>.bananatheme`, then run `Scripts/theme-catalog.py build <iTerm2-Color-Schemes checkout>` to refresh `index.json`.
3. Check a file locally with `Scripts/theme-catalog.py validate <file>`. The **Theme catalog** workflow runs the same check on pull requests and verifies the index matches the files.

## Catalog

`Sources/PromptSupport/Catalog` holds `index.json` (metadata and preview colors for every theme, with each file's SHA-256), the theme files, and `likes.json`. The app ships with this folder for offline use and refreshes it from the repository's `main` branch; downloaded files must match the index checksum. The default marketplace also fetches the [Gogh palette feed](https://raw.githubusercontent.com/Gogh-Co/Gogh/master/data/themes.json) and caches the last valid feed for offline use. Existing color schemes take precedence when normalized names match. Gogh entries retain their author and can be found by searching for Gogh. Set the `themeCatalogURL` default to an HTTPS folder to use another catalog on its own.

The color schemes come from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes); only schemes whose recorded licence permits redistribution are included (see `Catalog/LICENSE.txt`).

### Ratings

Each catalog theme can have a GitHub issue labelled `theme` and titled `[theme] <id>`. **Rate on GitHub** opens it; 👍 and ❤️ reactions count as likes. `Scripts/update-theme-likes.sh` tallies them into `likes.json` (it needs the GitHub CLI), and the next `build` puts them in the index, where the gallery's **Popular** order uses them.
