-- Example tmux-style configuration
-- Add to Rex's init.lua, apply with `rex config reload`

-- Ctrl+A prefix, followed by Ctrl+S to open resh or Shift+L for the previous session
local prefix = "ctrl+[KeyA]>"
rex.bind(prefix .. "ctrl+[KeyS]", "resh")
rex.bind(prefix .. "shift+[KeyL]", "resh_last")

-- Inside the picker, use Ctrl directly, without the prefix
rex.bind("resh/ctrl+[KeyE]", "resh_source", { name = "Sessions" })
rex.bind("resh/ctrl+[KeyA]", "resh_source", { name = "Agents" })
rex.bind("resh/ctrl+[KeyJ]", "resh_source", { name = "Projects" })
rex.bind("resh/ctrl+[KeyR]", "resh_source", { name = "Recent" })
rex.bind("resh/ctrl+[KeyF]", "resh_source", { name = "Find" })

rex.bind("resh/ctrl+[KeyN]", "resh_next")
rex.bind("resh/ctrl+[KeyP]", "resh_previous")
rex.bind("resh/ctrl+[KeyK]", "resh_previous")
rex.bind("resh/ctrl+tab", "resh_next_source")
rex.bind("resh/ctrl+shift+tab", "resh_previous_source")

rex.bind("resh/ctrl+shift+[KeyN]", "resh_create") -- Use the search text as the session name
rex.bind("resh/ctrl+shift+[KeyP]", "resh_pin")
rex.bind("resh/ctrl+shift+[KeyD]", "resh_delete") -- Close immediately

for number = 1, 9 do
	rex.bind("resh/ctrl+[Digit" .. number .. "]", "resh_open", { number = number })
end

-- Custom view
-- rex.bind("resh/ctrl+[KeyW]", "resh_source", { name = "Work" })

-- Disable default shortcuts
-- rex.unbind("resh/cmd+[KeyA]", "resh_source")
-- rex.unbind("cmd+[KeyS]", "resh")
