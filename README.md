# bananaShell

bananaShell is a tabbed macOS terminal for local login shells. It uses SwiftTerm to connect the terminal display to a pseudoterminal (PTY).

The terminal uses bundled JetBrains Mono NL Nerd Font Mono at 14 pt with 1.15× line spacing. Theme previews use the same font so prompt icons work without a separate font installation. Browse Oh My Posh and Starship previews directly in the theme list.

## Run the app

In Xcode, open `bananaShell.xcodeproj`, select the **bananaShell** scheme and **My Mac**, then press ⌘R. Alternatively, run the following command from the project directory on a Mac with the Swift toolchain installed. SwiftPM downloads dependencies on the first run.

```sh
swift run bananaShell
```

## Use the terminal

Press ⌘C to copy selected text, ⌘V to paste, or Control-C to interrupt a running command. Open a tab with ⌘T and close it with ⌘W or `exit`. Closing the last tab quits the app.

Drag a terminal tab onto another tab to reorder it. Press ⌘1 through ⌘9 to select the first nine terminal tabs, ⌘0 for the tenth, ⌘- for the eleventh, or ⌘= for the twelfth. Shortcuts follow the current tab order and skip SSH Keys, Activity, and Automations. If no tab occupies that position, the selection stays unchanged.

Open **Prompt Settings** (⌘,) to enable the Powerline prompt, choose a design (Classic blocks, a Minimal single line, a Stacked two-line prompt, or a Ribbon with connected arrow segments and the active environment), pick an accent color, or show or hide the user and computer names. Built-in accents support any 24-bit sRGB color through the color picker or a six-digit HEX value. For a community theme, choose Oh My Posh or Starship under Theme library, search by name, and select it. These libraries use their own theme colors. Install the engines with `brew install oh-my-posh starship` on a new Mac. Bundled configurations come from the [Oh My Posh themes](https://github.com/JanDeDobbeleer/oh-my-posh/tree/main/themes) and [Starship presets](https://starship.rs/presets/); their licenses accompany the files. Changes recolor the tab bar and open zsh tabs immediately. An idle prompt redraws in place; running commands keep their terminal input and show the new prompt when they finish.

## SSH keys

Select SSH Keys and click **+** in the tab bar to generate a key or import an existing public key. Choose **Ed25519** (default), **RSA** (2048, 3072, or 4096 bits), or **ECDSA** (256, 384, or 521 bits), then enter a filename, comment, and optional passphrase. RSA defaults to 4096 bits and ECDSA to 256 bits. Suggested filenames follow the selected key type; custom filenames are preserved. bananaShell saves the key in `~/.ssh` without overwriting existing files. The public key then appears in the list.

## Automations

Select Automations (the clock icon) and click **+** in the tab bar to open a recording zsh session in your home directory. Commands run as you record. Enter your commands and any follow-up input, quit the interactive program, then type `exit` at the shell prompt.

Review the recording, give it a name, and choose a time. A LaunchAgent runs the recorded commands in order through `/usr/bin/expect` in a separate pseudoterminal. Each follow-up input is stored with excerpts of the output immediately before and after it. Playback stops if the expected output does not appear within 120 seconds or the shell prompt returns first. Output that changes between runs, such as timestamps, may not match. Older time-based recordings retain their original playback behavior.

Click ▶ in Automations to run a task immediately without changing its schedule. Expand the task to view the latest 64 KiB of standard output and standard error in its Run Log. The view refreshes every two seconds. Log files are stored in `~/Library/Logs/bananaShell/`.

By default, new recordings ask for approval each time a supported confirmation prompt such as `[Y/n]` or `(y/N)` appears. The dialog shows the task name and question. If you decline or do not respond within two minutes, bananaShell sends `n` and stops playback. To send `y` and Enter automatically, select the automatic approval option in Automations. Record older automations again to use this feature.

**Ask me** 자동화가 입력을 기다리면 펼쳐진 Run Log에 질문과 선택 버튼이 나타납니다. 버튼은 해당 실행의 현재 질문에만 답하며, 기록만 남은 과거 질문에는 표시되지 않습니다. 로그 화면을 보고 있지 않으면 기존 macOS 확인 창을 사용합니다.
