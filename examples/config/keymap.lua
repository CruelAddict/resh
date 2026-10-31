-- Add to Rex's init.lua AFTER the installed resh integration.
-- Apply with: rex config reload. The existing picker updates without restarting.
-- Bindings in the resh mode extend the picker's defaults, without changing Rex's
-- normal keyboard controls. [KeyX] names a physical key; x follows the layout.

rex.bind("resh/ctrl+[KeyT]", "resh_source", { id = "sessions" })
rex.bind("resh/ctrl+[KeyA]", "resh_source", { id = "all" })
rex.bind("resh/ctrl+[KeyG]", "resh_source", { id = "configs" })
rex.bind("resh/ctrl+[KeyX]", "resh_source", { id = "directories" })
rex.bind("resh/ctrl+[KeyF]", "resh_source", { id = "find" })
-- Custom sources use their TOML id; changing a view title leaves bindings intact:
-- rex.bind("resh/ctrl+[KeyW]", "resh_source", { id = "work" })

rex.bind("resh/ctrl+[KeyJ]", "resh_next")
rex.bind("resh/ctrl+[KeyK]", "resh_previous")
rex.bind("resh/ctrl+[KeyO]", "resh_open")
rex.bind("resh/ctrl+[KeyQ]", "resh_dismiss")
rex.bind("resh/ctrl+shift+[KeyD]", "resh_delete") -- closes immediately
rex.bind("resh/ctrl+shift+[KeyN]", "resh_create") -- names the session after the query
rex.bind("resh/ctrl+shift+[KeyP]", "resh_pin")
rex.bind("resh/ctrl+tab", "resh_next_source")
rex.bind("resh/ctrl+shift+tab", "resh_previous_source")
for number = 1, 9 do
  rex.bind("resh/ctrl+[Digit" .. number .. "]", "resh_open", { number = number })
end

-- Remove this action's default binding and return Cmd+A to native text editing.
rex.unbind("resh/cmd+[KeyA]", "resh_source")
-- Without the action argument, rex.unbind blocks the key inside that mode.

-- Sequences and nested modes use the same Rex API as the app:
-- rex.bind("resh/ctrl+b>j", "resh_next")
-- rex.bind("resh/ctrl+b>k", "resh_previous")
-- rex.bind("resh/ctrl+r", "client.mode.enter", { name = "pick", once = true })
-- rex.mode("pick", { exclusive = true })
-- rex.bind("pick/j", "resh_next")
-- rex.bind("pick/k", "resh_previous")
