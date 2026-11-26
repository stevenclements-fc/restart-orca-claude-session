# restart-claude-sessions

This tool restarts the other running Claude Code CLI sessions on a Mac. Each session restarts in its own Orca pane and resumes its exact conversation with `claude <original flags> --resume <session-id>`.

## Files

- `restart-claude-sessions.zsh`: the script. A zsh script with embedded Python. Run `--help` for its options.
- `skill/SKILL.md`: the user-invoked Claude Code skill `/restart-claude-sessions`.
- `hotkeys/hammerspoon.lua`: the hotkey binding for Hammerspoon.
- `hotkeys/karabiner.json`: the hotkey rule for Karabiner-Elements.

The installed copies are symbolic links to this folder. Edit the files here, never the installed links.

## Install on a Mac

Run these steps from this folder. Each step is done when its check passes.

1. Check the prerequisites: `uname` prints `Darwin`, and `claude` and `python3` are on PATH.
   If Orca is not installed, tell the user: only sessions in Orca panes restart, all other sessions stay running.
2. Link the script:
   `mkdir -p ~/bin && ln -sfn "$PWD/restart-claude-sessions.zsh" ~/bin/restart-claude-sessions.zsh`
   If a regular file already exists at the target, show the user the diff and ask before you replace it.
3. Link the skill:
   `mkdir -p ~/.claude/skills && ln -sfn "$PWD/skill" ~/.claude/skills/restart-claude-sessions`
   Apply the same check as step 2.
4. Add the alias. Skip this step when `grep -q restart-claude-sessions ~/.zshrc` succeeds. Otherwise append:
   ```zsh
   # Restart the other Claude Code sessions and resume each one (see --help)
   alias restart-claude-sessions="$HOME/bin/restart-claude-sessions.zsh"
   ```
5. Verify: `~/bin/restart-claude-sessions.zsh --self-test` prints `self-test ok`.
   Then run `--dry-run` and show the user the table. The dry run changes nothing.
6. Install the hotkey. Follow "Hotkey" below. Ask the user before you change any hotkey configuration.

The install is done when steps 1–5 pass and the user has accepted or declined the hotkey.

## Hotkey

The hotkey runs `~/bin/restart-claude-sessions.zsh --gui`. The script lists the sessions in a macOS dialog. Cancel is the default button, and the dialog cancels itself after 60 seconds. A notification reports the result.

1. Find the hotkey tool. Hammerspoon is present when `~/.hammerspoon/init.lua` exists. Karabiner-Elements is present when `~/.config/karabiner/karabiner.json` exists.
   If neither is present, skip the hotkey and tell the user.
2. Ask the user with AskUserQuestion: install the hotkey or not, and which key. Offer hyper+r first.
   Read the existing configuration first, and tell the user if the key is already bound.
3. Hammerspoon:
   - Add the binding from `hotkeys/hammerspoon.lua` to `~/.hammerspoon/init.lua`. Reuse the hyper modal of the existing configuration. Put the binding above the final `hs.alert.show("Config loaded")` line when that line exists.
   - Reload: `osascript -e 'quit app "Hammerspoon"'; open -a Hammerspoon`.
4. Karabiner-Elements:
   - Find how `karabiner.json` defines hyper. A common rule maps caps_lock to left_command, left_control, left_option and left_shift.
   - Copy `hotkeys/karabiner.json` to `~/.config/karabiner/assets/complex_modifications/restart-claude-sessions.json`. In the copy, make the `mandatory` modifiers match that hyper definition.
   - Tell the user to enable the rule: Karabiner-Elements > Complex Modifications > Add predefined rule > "Hyper+R: restart Claude Code sessions".
   - Edit `karabiner.json` directly only when the user asks. Back it up first.
5. Ask the user to press the hotkey and click Cancel. The hotkey works when the dialog opens.

## How the script works

Read this before you change the script.

- It finds every `claude` process on a `/dev/ttys*` terminal. It excludes its own process and all ancestors, so the calling session survives.
- It reads exact argv and environment through `sysctl KERN_PROCARGS2`. `ps -o args=` loses quoting, for example in `--plugin-dir …/Application Support/…`.
- The session ID comes from `~/.claude/sessions/<pid>.json` first. That file holds the live ID, which is correct after `/clear`. The fallbacks are in the script header.
- A transcript guess is accepted only when exactly one unclaimed transcript is newer than the process. Wrong guesses resume another session's conversation.
- The relaunch command drops `--resume`, `--continue`, `--session-id`, `--fork-session`, `--print` and the start prompt. The script reads the option list from `claude --help`. It stops when that list is empty.
- It types the relaunch command with `orca terminal send`, through the `ORCA_TERMINAL_HANDLE` of the target process. macOS refuses TIOCSTI to other terminals for non-root users.
- A session that another `claude` process started (environment has `CLAUDE_PID`) inherits the parent's Orca handle. The script ignores that handle.
- The script never stops a session that it cannot relaunch: no resumable transcript, or no Orca pane.

After any change, run `./restart-claude-sessions.zsh --self-test` and `./restart-claude-sessions.zsh --dry-run`.
