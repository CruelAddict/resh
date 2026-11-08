-- Shortcuts might be overridden in Rex's Lua config
-- Apply changes with `rex config reload`
-- Note: '[KeyX]' makes a shortcut layout-independent, as opposed to plain 'x'

-- Global Rex shortcuts, automatically installed in init.lua through resh.lua during resh installation
rex.bind("cmd+[KeyS]", "resh") -- Open or close the picker
rex.bind("cmd+[KeyL]", "resh_last") -- Toggle between the last two sessions opened through resh

-- The default shortcuts below are supplied by resh's binary and don't need to be in your init.lua
rex.bind("resh/cmd+[KeyE]", "resh_source", { name = "Sessions" })
rex.bind("resh/cmd+[KeyA]", "resh_source", { name = "Agents" })
rex.bind("resh/cmd+[KeyR]", "resh_source", { name = "Recent" })
rex.bind("resh/cmd+[KeyF]", "resh_source", { name = "Find" })
rex.bind("resh/cmd+[KeyP]", "resh_source", { name = "Projects" })

rex.bind("resh/cmd+shift+[KeyN]", "resh_create") -- Create a new session
rex.bind("resh/cmd+shift+[KeyP]", "resh_pin") -- Pin or unpin the selected session
rex.bind("resh/cmd+shift+[KeyD]", "resh_delete") -- Close the selected session

rex.bind("resh/ctrl+[KeyN]", "resh_next") -- Select the next result
rex.bind("resh/down", "resh_next")
rex.bind("resh/ctrl+[KeyP]", "resh_previous") -- Select the previous result
rex.bind("resh/up", "resh_previous")
rex.bind("resh/tab", "resh_next_source") -- Select the next view
rex.bind("resh/shift+tab", "resh_previous_source") -- Select the previous view
rex.bind("resh/enter", "resh_open") -- Open the selected result
rex.bind("resh/[NumpadEnter]", "resh_open")
rex.bind("resh/escape", "resh_dismiss") -- Close the picker
rex.bind("resh/ctrl+[BracketLeft]", "resh_dismiss")

-- Open the first nine results by number
for number = 1, 9 do
	rex.bind("resh/cmd+[Digit" .. number .. "]", "resh_open", { number = number })
end
