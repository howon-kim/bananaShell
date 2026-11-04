# bananaShell

bananaShell is a tabbed macOS terminal for local login shells. It uses SwiftTerm to connect the terminal display to a pseudoterminal (PTY).

The terminal uses bundled JetBrains Mono NL Nerd Font Mono at 14 pt with 1.15× line spacing. Theme previews use the same font so prompt icons work without a separate font installation. Browse Oh My Posh and Starship previews directly in the theme list.

## Run the app

In Xcode, open `bananaShell.xcodeproj`, select the **bananaShell** scheme and **My Mac**, then press ⌘R. Alternatively, run the following command from the project directory on a Mac with the Swift toolchain installed. SwiftPM downloads dependencies on the first run.

```sh
swift run bananaShell
```

## Use the terminal

Press ⌘C to copy selected text, ⌘V to paste, or Control-C to interrupt a running command. New terminal tabs start in your home directory (`~`). Open a tab with ⌘T and close it with ⌘W or `exit`. Closing the last tab quits the app.

Drag a terminal tab onto another tab to reorder it. Press ⌘1 through ⌘9 to select the first nine terminal tabs, ⌘0 for the tenth, ⌘- for the eleventh, or ⌘= for the twelfth. Shortcut numbers stay with each terminal, even after closing or reordering tabs. Closing a terminal leaves its number available; a new terminal takes the lowest available number. Group tabs, Keys, and Automations do not use terminal numbers. If no tab occupies that position, the selection stays unchanged.

The top row contains your groups. Click a group to see its terminal grid, or double-click its name to rename it. The top **+** or ⌘G creates a group. Press ⌘P to start a new page with a focused terminal, even if the previous page still has room. In Settings → Keyboard shortcuts, click a Create keycap and press Command, Option, or Control plus a letter. Click a Select keycap and press the modifier with a number from the top row. Escape cancels recording. The second row contains just that group’s terminal tabs: click one to open the terminal at full size, or use the lower **+** (⌘T) to add a terminal. In a 2×2 or 4×4 grid, double-click a terminal’s title bar to open the same session at full size. Click the group again to return to its grid. Use the grid icons marked **1**, **4**, or **16** to choose how many terminals appear on each page; the terminal strip groups each page’s terminals together in multi-cell layouts. The 1×1 layout shows terminal tabs without page labels. Click the page label at the start of a group to show its grid. The current page stays expanded. Other pages show just their labels; hover over a label to preview its terminal tabs without changing the grid. Each page label shows its shortcut.

By default, use **⌃1–9** to select a group by its position in the title bar, or **⌥1–9** to select a page in the current group. **0** selects the tenth group or page. Group and page tabs show these shortcuts beside their names. In the grid with no terminal focused, **[** and **]** change pages directly. When typing in a terminal they remain ordinary characters; use **⌥[** or **⌥]** to switch pages, or press Escape in the grid to release terminal focus first. Use **⌃[** and **⌃]** to cycle groups. In Settings → Keyboard shortcuts, change the Select modifier for Group, Page, or Terminal. Choosing an occupied modifier swaps the two rows. Number keys stay fixed; bracket navigation follows the group and page modifiers, and the terminal modifier also applies to minus and equals.

Use the move menu in the second row to bring a running terminal into this group. Click × on a group to move its terminals to the adjacent group and close the group. One group stays open. Click × on a page to review how many terminals it contains and close those sessions together. A terminal’s own × closes just that session. In the grid, click a terminal to type or use its usual ⌘ shortcut to jump to its group and page. Escape or the same shortcut releases keyboard focus. **Reopen last window on launch** restores group names, layouts, and terminal assignments.

Open **Prompt Settings** (⌘,) to enable the Powerline prompt, choose a design (Classic blocks, a Minimal single line, a Stacked two-line prompt, or a Ribbon with connected arrow segments and the active environment), pick an accent color, or show or hide the user and computer names. Built-in accents support any 24-bit sRGB color through the color picker or a six-digit HEX value. For a community theme, choose Oh My Posh or Starship under Theme library, search by name, and select it. These libraries use their own theme colors. **Match interface accent** uses the applied theme’s accent for tabs, buttons, and selections independently of the terminal background. Turn it off to keep the interface mint. Install the engines with `brew install oh-my-posh starship` on a new Mac. Bundled configurations come from the [Oh My Posh themes](https://github.com/JanDeDobbeleer/oh-my-posh/tree/main/themes) and [Starship presets](https://starship.rs/presets/); their licenses accompany the files. Changes recolor the tab bar and open zsh tabs immediately. An idle prompt redraws in place; running commands keep their terminal input and show the new prompt when they finish.

## Keys

The **Keys** tab groups SSH public keys and API keys in one searchable list. Search by name, service, related link, file, fingerprint, or key type. API key values are excluded from search.

For SSH keys, click **+ → Generate SSH Key…** or **Import SSH Public Key…**. Choose **Ed25519** (default), **RSA** (2048, 3072, or 4096 bits), or **ECDSA** (256, 384, or 521 bits), then enter a filename, comment, and optional passphrase. RSA defaults to 4096 bits and ECDSA to 256 bits. Suggested filenames follow the selected key type; custom filenames are preserved. bananaShell saves the key in `~/.ssh` without overwriting existing files. The public key then appears in the list.

For API keys, click **+ → Add API Key…**, enter a name, an optional service and related link, and the key value. Use the related link for a provider dashboard or API documentation; click its card in the detail to open it in your browser. Links accept full HTTP or HTTPS addresses without embedded sign-in details. Values are stored in the [local macOS Keychain](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) without enabling iCloud synchronization. Listing keys reads metadata only; values are retrieved when you choose Show or Copy. Revealed values hide after 30 seconds, when the app loses focus, or when the detail closes. The Copy button clears its clipboard contents after 60 seconds while the app is open, provided nothing else has been copied. Click the pencil beside the key in the list to rename it, change its service or link, or replace its value; leaving the replacement empty preserves the saved value. **Delete API Key…** asks before removing it from Keychain.

## Automations

Select Automations (the clock icon) and click **+** in the tab bar to open a recording zsh session in your home directory. Commands run as you record. Enter your commands and any follow-up input, quit the interactive program, then type `exit` at the shell prompt.

Review the recording, give it a name, and choose a time. A LaunchAgent runs the recorded commands in order through `/usr/bin/expect` in a separate pseudoterminal. Each follow-up input is stored with excerpts of the output immediately before and after it. Playback stops if the expected output does not appear within 120 seconds or the shell prompt returns first. Output that changes between runs, such as timestamps, may not match. Older time-based recordings retain their original playback behavior.

Automations uses the same searchable list and detail layout as Keys. Search by name, command, folder, or schedule, then select a task to see its terminal and settings. On narrow windows, use **All Automations** to return to the list. Click ▶ in the list or **Run now** in the detail to run a task immediately without changing its schedule; the same control stops a running task. The detail also contains the command, working directory, confirmation policy, and an actions menu. Choose **Edit Automation…** to update the name, schedule, working directory, or commands. For a recorded session, use **Replace recording…** to record new commands and responses.

Running tasks open their detail with a live terminal using the same 14 pt font and 1.15× line spacing as your tabs. Colors, progress redraws and cursor movement update at 100 ms intervals. You can scroll back and copy text; use the confirmation buttons below the terminal to answer questions. The terminal stays visible after completion. Reopening a task loads up to 1 MiB of recent output, then streams new bytes without rereading its history. Recorded jobs also follow the terminal’s width and height. Log files remain in `~/Library/Logs/bananaShell/`.

By default, new recordings ask for approval each time a supported confirmation prompt such as `[Y/n]` or `(y/N)` appears. The dialog shows the task name and question and waits for your response. If you decline, bananaShell sends `n` and stops playback. To send `y` and Enter automatically, select the automatic approval option in Automations. Record older automations again to use this feature.

**Ask me** 자동화가 입력을 기다리면 상세 화면의 실시간 터미널 아래에 질문과 선택 버튼이 나타납니다. 버튼은 해당 실행의 현재 질문에만 답하며, 기록만 남은 과거 질문에는 표시되지 않습니다. 자동화 화면을 보고 있지 않으면 macOS 알림으로 답할 수 있습니다.
