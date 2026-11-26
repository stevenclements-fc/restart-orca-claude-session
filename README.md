# restart-orca-claude-session

Restart every running Claude Code session in its Orca pane, and resume each one where it left off.

## Why

A Claude Code update, a new plugin or a settings change takes effect only after a restart. With many sessions open, a restart by hand means finding each session's ID and original flags, one pane at a time. This tool does it in one command.

## What it does

1. It finds every `claude` session that runs in a terminal, except the one that runs the script.
2. For each session, it reads the session ID, the working directory and the original flags, for example `--model`, `--effort` and `--permission-mode`.
3. It shows a table and asks for confirmation.
4. It stops each session and types `claude <original flags> --resume <session-id>` into the same Orca pane.

The tool never stops a session that it cannot bring back. It lists such sessions and leaves them running:

- A session outside an Orca pane, for example in iTerm2, Warp or Terminal.app. macOS blocks typing into those terminals.
- A session with no saved conversation on disk.

## Requirements

- macOS
- Claude Code (`claude`) and `python3` on PATH
- Orca, for the panes that restart
- Optional: Hammerspoon or Karabiner-Elements for the hotkey

## Install

### With an agent

Clone the repository, open Claude Code in the folder, and say "install this". The agent follows `AGENTS.md`. It asks before it installs a hotkey.

### By hand

```zsh
git clone git@github.com:stevenclements-fc/restart-orca-claude-session.git
cd restart-orca-claude-session
mkdir -p ~/bin ~/.claude/skills
ln -sfn "$PWD/restart-claude-sessions.zsh" ~/bin/restart-claude-sessions.zsh
ln -sfn "$PWD/skill" ~/.claude/skills/restart-claude-sessions
echo 'alias restart-claude-sessions="$HOME/bin/restart-claude-sessions.zsh"' >> ~/.zshrc
~/bin/restart-claude-sessions.zsh --self-test
```

For the hotkey, see `hotkeys/` and the "Hotkey" section of `AGENTS.md`.

## Usage

```zsh
restart-claude-sessions --dry-run          # show the sessions and relaunch commands; change nothing
restart-claude-sessions                    # restart, after a y/N prompt
restart-claude-sessions --skip 123,456     # leave these process IDs running
restart-claude-sessions --only 123         # restart only these process IDs
restart-claude-sessions --gui              # confirm in a macOS dialog; used by the hotkey
restart-claude-sessions --help
```

In Claude Code, type `/restart-claude-sessions`. The skill shows the sessions and asks which ones to restart. You can add a choice, for example `/restart-claude-sessions skip the frontend ones`.

With the hotkey (hyper+r by default), a dialog lists the sessions. Cancel is the default button. A notification reports the result.

## Files

- `restart-claude-sessions.zsh`: the script
- `skill/SKILL.md`: the Claude Code skill
- `hotkeys/hammerspoon.lua`, `hotkeys/karabiner.json`: the hotkey bindings
- `AGENTS.md`: install steps and how the script works, for agents and maintainers
