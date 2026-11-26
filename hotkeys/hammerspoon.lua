-- Restart Claude Code sessions with hyper+r. The script asks for confirmation in a macOS dialog.
-- Add this to ~/.hammerspoon/init.lua. It uses the `hyper` modal of the existing config.
-- With no hyper modal, use: hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "r", function() ... end)
hyper:bind({}, "r", function()
  hs.task.new(os.getenv("HOME") .. "/bin/restart-claude-sessions.zsh", nil, {"--gui"}):start()
end)
