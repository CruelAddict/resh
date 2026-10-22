-- Optional Rex keymap modeled on ~/.tmux.conf: Ctrl+A is the prefix.
-- Hardware positions keep these shortcuts working with Russian input too.
-- Load AFTER resh.lua. Existing Cmd shortcuts are intentionally preserved.
-- After editing, use Reload Config in the Rex app so its keymap is refreshed too.
local prefix = "ctrl+[KeyA]>"
local function bind(key, action, args)
  rex.bind(prefix .. key, action, args)
end

-- Tabs correspond to tmux windows.
bind("[KeyC]", "client.tab.new")
bind("[KeyN]", "client.tab.next")
bind("[KeyP]", "client.tab.previous")
-- tmux also accepts C-n/C-p: keep Ctrl held after pressing the prefix.
bind("ctrl+[KeyN]", "client.tab.next")
bind("ctrl+[KeyP]", "client.tab.previous")
bind("[Comma]", "client.tab.rename")

-- This tmux setup uses base-index 0; Rex's tab indexes start at 1.
for number = 0, 9 do
  bind("[Digit" .. number .. "]", "client.tab.goto", { index = number + 1 })
end

-- % and double quote on a US keyboard.
bind("shift+[Digit5]", "pane.split", { direction = "right" })
bind("shift+[Quote]", "pane.split", { direction = "down" })

for key, direction in pairs({
  KeyH = "left", KeyJ = "down", KeyK = "up", KeyL = "right",
  ArrowLeft = "left", ArrowDown = "down", ArrowUp = "up", ArrowRight = "right",
}) do
  bind("[" .. key .. "]", "pane.focus", { direction = direction })
end
bind("[KeyO]", "pane.focus_next")
bind("[KeyZ]", "pane.zoom")
bind("[KeyX]", "pane.close")

-- Session controls and the sesh-style picker.
bind("[KeyS]", "session.switch")
bind("shift+[KeyS]", "session.new")
bind("shift+[KeyK]", "session.close")
bind("shift+[Digit4]", "session.rename")
bind("ctrl+[KeyS]", "resh")

-- Ctrl+A twice sends one literal Ctrl+A to the focused terminal.
bind("ctrl+[KeyA]", "pane.send_key", { key = "ctrl+a" })
