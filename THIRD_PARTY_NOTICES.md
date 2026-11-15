# Third-party notices

bananaShell's own code is licensed under the MIT License (see `LICENSE`).
The following bundled components keep their own licenses, included next to the files.

| Component | Location | License | License file |
| --- | --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Swift package dependency | MIT | upstream repository |
| [Zstandard](https://github.com/facebook/zstd) (decoder) | `Vendor/BananaZstd` | BSD-3-Clause | `Vendor/BananaZstd/LICENSE`, `Sources/PromptSupport/zstd-LICENSE.txt` |
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) | `Sources/Fonts` | SIL OFL 1.1 | `Sources/Fonts/JetBrainsMono-OFL.txt` |
| [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) patches | `Sources/Fonts` | MIT / various | `Sources/Fonts/NerdFonts-LICENSE.txt` |
| [SUITE](https://github.com/sun-typeface/SUITE) | `Sources/Fonts` | SIL OFL 1.1 | `Sources/Fonts/SUITE-LICENSE.txt` |
| [Oh My Posh themes](https://github.com/JanDeDobbeleer/oh-my-posh) | `Sources/PromptSupport/Oh My Posh` | MIT | `Sources/PromptSupport/Oh My Posh/COPYING` |
| [Starship presets](https://starship.rs/presets/) | `Sources/PromptSupport/Starship` | ISC | `Sources/PromptSupport/Starship/LICENSE` |
| Program logos | `Sources/ProgramLogos` | see below | — |

## Program logos

The icons in `Sources/ProgramLogos` depict products and services of their
respective owners. All product names, logos and brands are trademarks of their
owners; their use here identifies the program running in a terminal and implies
no endorsement.

tmux is not bundled; bananaShell runs the copy installed on your system.
