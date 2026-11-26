---
name: restart-claude-sessions
description: Restart the other running Claude Code sessions in their Orca panes and resume each exact session.
disable-model-invocation: true
---

The script `~/bin/restart-claude-sessions.zsh` does the work. It never restarts the session that runs it.
Text after the command is the user's selection, for example "skip the sub-agreement sessions".

1. Run `~/bin/restart-claude-sessions.zsh --dry-run`. Show the user each session it would restart: PID, NAME, STATUS, CWD.
   Mark every `busy` session: a restart interrupts its turn.
2. Ask with AskUserQuestion which sessions to restart. Offer all, and all except the busy ones, unless the user's selection already answers it.
3. Run `~/bin/restart-claude-sessions.zsh --yes --only <PID,PID,...>` with exactly the confirmed PIDs.
   `--only` keeps a session that started after the dry run out of the restart.
4. Done when every confirmed PID shows `relaunched via …` or a line under "Run these by hand".
   Report each PID by NAME, and give the by-hand commands verbatim.
